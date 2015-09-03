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
RUN echo "jenkins ALL=(ALL) NOPASSWD: ALL" > /etc/sudoers.d/jenkins

# Install Docker from Docker Inc. repositories.
RUN echo deb https://get.docker.io/ubuntu docker main > /etc/apt/sources.list.d/docker.list \
  && apt-key adv --keyserver hkp://keyserver.ubuntu.com:80 --recv-keys 36A1D7869245C8950F966E92D8576A8BA88D21E9 \
  && apt-get update -qq \
  && apt-get install -qqy lxc-docker

RUN gpasswd -a jenkins docker

ADD build-essentials.sh  /opt/install/build-essentials.sh
RUN chmod +x  /opt/install/build-essentials.sh
RUN /opt/install/build-essentials.sh

# Install the magic docker wrapper and sshd startup script
ADD ./entrypoint.sh /usr/local/bin/entrypoint.sh
RUN chmod +x /usr/local/bin/entrypoint.sh

# Install Docker/Compose buildscript
ADD docker-build.pl /usr/local/bin/docker-build
RUN chmod +x /usr/local/bin/docker-build

# Downloading android-sdk
RUN wget http://dl.google.com/android/android-sdk_r24.3.2-linux.tgz; \
    tar zxvf android-sdk_r24.3.2-linux.tgz; \
    mv android-sdk-linux /usr/local/bin/android-sdk ; \
    rm android-sdk_r24.3.2-linux.tgz

#Add env-variables
ENV ANDROID_HOME /usr/local/bin/android-sdk
ENV PATH $PATH:$ANDROID_HOME/tools
ENV PATH $PATH:$ANDROID_HOME/platform-tools

#Update android-libs and other dependencies
RUN ( sleep 5 && while [ 1 ]; do sleep 1; echo y; done ) | android update sdk --no-ui --all --filter 139; \
	( sleep 5 && while [ 1 ]; do sleep 1; echo y; done ) | android update sdk --no-ui --all --filter 140; \
	( sleep 5 && while [ 1 ]; do sleep 1; echo y; done ) | android update sdk --no-ui --all --filter build-tools-21.1.2; \
	( sleep 5 && while [ 1 ]; do sleep 1; echo y; done ) | android update sdk -u --filter platform-tools,android-21; \
	( sleep 5 && while [ 1 ]; do sleep 1; echo y; done ) | android update sdk -u --filter extra-google-m2repository
RUN apt-get install -y --no-install-recommends g++-multilib lib32z1

# Define additional metadata for our image.
VOLUME /var/lib/docker
EXPOSE 22 2375

CMD ["/usr/local/bin/entrypoint.sh"]
