set -ex
set -o pipefail

apt-get update -qq && apt-get install -y \
pxz \
build-essential \
pbuilder \
curl \
git \
dh-make \
dh-make-perl \
pbuilder-scripts \
ubuntu-dev-tools \
libncurses5-dev \
zlib1g-dev \
gawk \
subversion \
libssl-dev \
libfile-slurp-perl \
libipc-system-simple-perl \
libgetopt-long-perl \
libxml-parser-perl

# Install docker-compose
echo -n "Installing docker-compose ... "
curl -s -L https://github.com/docker/compose/releases/download/1.3.3/docker-compose-`uname -s`-`uname -m` > /usr/local/bin/docker-compose
chmod +x /usr/local/bin/docker-compose
echo ok
