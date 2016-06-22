#!/usr/bin/env perl

use strict;
use warnings;

use 5.010;

use Cwd qw(abs_path cwd getcwd);
use Data::Dumper qw(Dumper);
use File::Basename qw(basename dirname);
use Getopt::Long qw(GetOptions);
use Pod::Usage qw(pod2usage);
use IPC::System::Simple qw(capture system EXIT_ANY $EXITVAL);
use YAML::XS qw(LoadFile DumpFile);
use File::Slurp qw(read_file write_file);

use constant {
  FILE_META       => 'build.meta.yml',
  FOLDER_UPSTREAM => './upstream_project/',
};

# Vars
my @steps;
my $step   = 0;
my $quiet  = 0;
my $push   = 0;
my $help   = 0;
my $org;
my $iwd = getcwd();
my $file;
my $image;
my $nosave;
my $registry;
my @tags;
my $replace_from;
my @dockercmd;
my @dockercmdp;

# Read CLI options
my $c = GetOptions(
  "help|?"         => \$help,
  "path:s"         => \$file,
  "image=s"        => \$image,
  "nosave:1"       => \$nosave,
  "org:s"          => \$org,
  "push:1"         => \$push,
  "registry:s"     => \$registry,
  "replace-from:s" => \$replace_from,
  "tag:s"          => \@tags,
  "dockercmd:s"    => \@dockercmdp,
  "quiet:1"        => \$quiet,
) or pod2usage(2);
pod2usage(1) if $help;

# Defaults
$image //= $ENV{IMAGE_NAME};
$file  //= $ENV{COMPOSEFILE}  // $ENV{DOCKERFILE};
$org   //= $ENV{ORGANIZATION} // 'ocedo';
unless ( @tags ) {
  push @tags, $ENV{BUILD_NUMBER} if defined $ENV{BUILD_NUMBER};
  push @tags, $ENV{BRANCH} // 'develop';
}
push @dockercmd, (
  ($ENV{DOCKER_HOST} ? 'DOCKER_HOST="'.$ENV{DOCKER_HOST}.'"' : ''),
  'docker',
), @dockercmdp;

# Registry
if ( $registry && $registry =~ /^([^:\@]+):([^:\@]+)\@([^:\@]+)$/ ) {
  $registry = {
    user => $1,
    pass => $2,
    name => $3,
  };
} elsif ( $registry ) {
  die "Invalid registry parameter format! Please specify --registry= \"user:pass\@name\"";
}
$registry->{mail} = 'autobuild@ocedo.com' if $registry;

# Check ENV
die "Missing image name! Either set IMAGE_NAME or specify --image=\"name\"" unless $image;

##
# File to work with (Compose-/Fig-/Dockerfile)
##
# No file given, try to find one
if ( ! $file || -d $file ) {
  for ( ('docker-compose.yml', 'fig.yml', 'Dockerfile') ) {
    if ( -f $file.'/'.$_ ) {
      $file = $file.'/'.$_;
      last;
    }
  }
}
unless ( -f $file && basename($file) =~ /^(Dockerfile|fig\.yml|docker-compose\.yml)$/ ) {
  die "No supported build file found or specified! (Compose-/Fig-/Dockerfile)";
}

# Use absolute path
$file = abs_path($file);

# Login to registry
docker_login() if $registry;

# Load upstream image?
docker_load() if $replace_from;

# Docker-Compose?
if ( $file =~ /\.yml$/ ) {
  my $c = LoadFile($file);

  my $main_image = $image;

  # Collect build steps
  for ( sort keys %{$c} ) {
    next unless $c->{$_}{build};
    push @steps, $_;
  }

  say "!! Using Compose file '".$file."' to build your App ".(@steps ? ' ('.@steps.' step'.(@steps > 1 ? 's' : '') : '').")";

  # Process build steps
  for ( @steps ) {
    my $dir;
    # v2 support
    if ( ref $c->{$_}{build} eq 'HASH' && $c->{$_}{build}{context} ) {
      $dir  = abs_path(dirname($file).($c->{$_}{build}{context} ? '/'.$c->{$_}{build}{context} : ''));
      $file = $c->{$_}{build}{dockerfile} ? $c->{$_}{build}{dockerfile} : 'Dockerfile';
    } else {
      $dir  = abs_path(dirname($file).'/'.$c->{$_}{build});
      $file = $c->{$_}{dockerfile} ? $c->{$_}{dockerfile} : 'Dockerfile';
    }
    chdir $dir or die "Failed to CHDIR into build directory: ".$dir;
    die "Failed to read Dockerfile: ".$file unless -r $file;
    $file = abs_path($file);

    # Use container_name for image?
    $image = $c->{$_}{container_name} ? $c->{$_}{container_name} : $main_image.'_'.$_;

    step();
  }
}
# Dockerfile
elsif ( $file =~ /Dockerfile$/ ) {
  say "!! Using Dockerfile '".$file."'";

  chdir dirname($file);

  step();
}

sub step {
  $step++;

  say "== STEP ".$step." / ".@steps." ==" if @steps;

  # Maintain .dockerignore
  my $dockerignore = '';
  read_file($iwd.'/.dockerignore') if -r $iwd.'/.dockerignore';
  $dockerignore .= "\n".FOLDER_UPSTREAM.'/*'."\n";
  write_file($iwd.'/.dockerignore', { binmode => ':utf8' }, $dockerignore);

  replace_from() if $replace_from;
  my $image_id   = docker_build();

  # Store meta data
  my $fp_meta = $iwd.'/'.FILE_META;
  my $meta   = -r $fp_meta ? LoadFile($fp_meta) : {};
  die "Build meta data for Image '".$image."' already exists!" if $meta->{$image};
  $meta->{$image} = {
    id   => $image_id,
    name => $org ? $org.'/'.$image : $image,
    tags => \@tags,
  };
  DumpFile($fp_meta, $meta) or die "Failed to save build meta data: '".$fp_meta."'";

  docker_save($image_id) unless $nosave;

  for ( @tags ) {
    my $image_tag  = docker_tag($image_id, $_, $push ? $registry->{name} : undef);
    docker_push($image_id, $image_tag) if $push;
  }
}

sub docker_login {
  say ":: Logging in to registry: ".$registry->{name};
  my $cmd = join(' ', @dockercmd)." login -e \"".$registry->{mail}."\" -u \"".$registry->{user}."\" -p \"".$registry->{pass}."\" ".$registry->{name};
  my $pcmd = $cmd;
  $pcmd =~ s/-p \"[^\"]+\"/-p \"XYZ\"/;
  print_cmd($pcmd);
  my @output = capture(EXIT_ANY, $cmd.' 2>&1');
  print_output(@output);
  die "Failed to login to registry" unless $EXITVAL == 0;
}

sub docker_load {
  say ":: Loading upstream Docker image ...";

  my $fp_meta = abs_path($iwd.'/'.FOLDER_UPSTREAM.'/'.FILE_META);
  my $meta = LoadFile($fp_meta) or die "Failed to read upstream build meta data: ".$fp_meta;
  die "Failed to find build meta data for upstream image '".$replace_from."': ".$fp_meta unless $meta->{$replace_from}{id};

  my $cmd = join(' ', @dockercmd)." load -i ".abs_path($iwd.'/'.FOLDER_UPSTREAM.'/'.$meta->{$replace_from}{file});
  print_cmd($cmd);
  my @output = capture(EXIT_ANY, $cmd.' 2>&1');
  print_output(@output);
  die "Failed to load upstream image" unless $EXITVAL == 0;
}

sub replace_from {
  die "Docker file not found" unless -r $file;

  my $fp_meta = abs_path($iwd.'/'.FOLDER_UPSTREAM.'/'.FILE_META);
  my $meta = LoadFile($fp_meta) or die "Failed to read upstream build meta data: ".$fp_meta;
  die "Failed to find build meta data for upstream image '".$replace_from."': ".$fp_meta unless $meta->{$replace_from}{id};

  my $image_id = $meta->{$replace_from}{id};
  my $dockerfile = read_file($file, { binmode => ':utf8' });
  unless ( $dockerfile =~ /^FROM\s+(.*)$/m ) {
    warn "Dockerfile has no FROM definition (wtf?)";
    return;
  }

  say ":: Modifying Dockerfile: FROM ".$1." -> ".$image_id." ...";

  $dockerfile =~ s/^FROM\s+.*$/FROM $image_id/m;
  write_file($file, { binmode => ':utf8' }, $dockerfile);
}

sub docker_build {
  die "Docker file not found"            unless -r $file;
  die "Cannot build: Missing image name" unless    $image;

  my $image_name = $org.'/'.$image;

  say ":: Building Image: ".$image_name." ...";

  # Build image and fetch ID
  my $cmd = join(' ', @dockercmd)." build --file=".$file." --rm=true --force-rm=true --no-cache=true --tag=".$image_name." ".$iwd;
  print_cmd($cmd);
  my @output = capture(EXIT_ANY, $cmd.' 2>&1');
  print_output(@output);
  die "Failed to build Image" unless $EXITVAL == 0;
  my $last_line = pop @output;
  $last_line =~ /^Successfully built (.+)$/ or die "Image-ID not found";

  my $image_id = $1;

  return $image_id;
}

sub docker_tag {
  my $image_id = shift;
  my $tag      = shift;
  my $reg      = shift;

  my $image_tag  = ($reg ? $reg.'/' : '').$org.'/'.$image.':'.$tag;

  say ":: Tagging Image: ".$image_tag." (".$image_id.")";

  # Tag Image
  my $cmd = join(' ', @dockercmd)." tag -f ".$image_id." ".$image_tag;
  print_cmd($cmd);
  my @output = capture(EXIT_ANY, $cmd.' 2>&1');
  print_output(@output);
  die "Failed to tag Image" unless $EXITVAL == 0;

  return $image_tag;
}

sub docker_save {
  my $image_id = shift;

  my $save_filename = 'docker-image_'.$image.'.tar.xz';
  my $save_file     = $iwd.'/'.$save_filename;
  my $image_name    = $org.'/'.$image;
  my $fh;

  say ":: Saving Image: ".$image_name." (".$image_id.")";

  die "Saved Image '".$save_file."' already exists!" if -e $save_file;

  # Save Image
  my $cmd = join(' ', @dockercmd)." save ".$image_id." | pxz -z -6 - > ".$save_file;
  print_cmd($cmd);
  my @output = capture(EXIT_ANY, $cmd.' 2>&1');
  print_output(@output);
  die "Failed to save Image" unless $EXITVAL == 0;

  # Store meta data
  my $fp_meta = $iwd.'/'.FILE_META;
  my $meta = -r $fp_meta ? LoadFile($fp_meta) : {};
  $meta->{$image}{file} = $save_filename;
  DumpFile($fp_meta, $meta) or die "Failed to save build meta data: '".$fp_meta."'";

  return $save_file;
}

sub docker_push {
  my $image_id  = shift;
  my $image_tag = shift;

  say ":: Pushing Image: ".$image_tag." (".$image_id.")";

  # Push Image
  my $cmd = join(' ', @dockercmd)." push ".$image_tag;
  print_cmd($cmd);
  my @output = capture(EXIT_ANY, $cmd.' 2>&1');
  print_output(@output);
  die "Failed to push Image" unless $EXITVAL == 0;
}

sub print_cmd {
  return if $quiet;
  print ' $ '.$_ for map { $_ =~ /\S/ ? $_ =~ /\n$/ ? $_ : $_."\n" : () } @_;
}

sub print_output {
  return if $quiet;
  print ' < '.$_ for map { $_ =~ /\S/ ? $_ =~ /\n$/ ? $_ : $_."\n" : () } @_;
}

__END__

=head1 NAME

docker-build.pl - Build Compose-/Fig-/Dockerfiles (and push to registry)

=head1 SYNOPSIS

docker-build.pl --image="foo" [options]

 Parameters:
   --image="foo"

 Options:
   -?, --help
   --org="ocedo"
   --path="/project"
   --registry="user:pass@registry"
   --push
   --quiet
   --tag="d'oh"

=head1 OPTIONS

=over 8

=item B<--image>

Name of (main) image. Image names from Compose are appended.

=back

=head1 OPTIONS

=over 8

=item B<-?, --help>

Print (a)this) brief help message and exit.

=item B<--org>

Organization to use when tagging your image

=item B<--nosave>

Don't save/export image

=item B<--path>

Dockerfile, fig.yml, docker-compose.yml to use

=item B<--push>

Push image to registry

=item B<--registry>

Registry credentials format: user:pass@registry

=item B<--replace-from>

Reads 'upstream_project/build.meta.yml' to get upstream build meta data.

Replaces FROM in Dockerfile(s) by Image ID from build meta data for specified image

=item B<--quiet>

Suppress Docker output (Don't use this for Jenkins)

=item B<--tag>

Image tag, e.g. build number

=back

=head1 DESCRIPTION

B<This program> builds docker images and can push them to a registry

=cut
