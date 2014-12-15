FROM ubuntu:latest
MAINTAINER Julian Klinck <git@lab10.de>

RUN apt-get update -qq && apt-get install -y \
    apt-transport-https \
    ca-certificates \
    lxc \
    iptables \
    openssh-server

RUN apt-get install -y --no-install-recommends openjdk-7-jdk

RUN mkdir -p /var/run/sshd

RUN adduser --quiet jenkins
RUN echo "jenkins:jenkins" | chpasswd

# Install Docker from Docker Inc. repositories.
RUN echo deb https://get.docker.io/ubuntu docker main > /etc/apt/sources.list.d/docker.list \
  && apt-key adv --keyserver hkp://keyserver.ubuntu.com:80 --recv-keys 36A1D7869245C8950F966E92D8576A8BA88D21E9 \
  && apt-get update -qq \
  && apt-get install -qqy lxc-docker

RUN gpasswd -a jenkins docker

# Install the magic docker wrapper and sshd startup script
ADD ./entrypoint.sh /usr/local/bin/entrypoint.sh
RUN chmod +x /usr/local/bin/entrypoint.sh

# Define additional metadata for our image.
VOLUME /var/lib/docker
EXPOSE 22 2375

ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
CMD ["/usr/sbin/sshd", "-D"]
