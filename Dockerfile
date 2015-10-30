FROM ubuntu:latest
MAINTAINER Julian Klinck <git@lab10.de>

RUN apt-get update -qq && apt-get install -y \
    apt-transport-https \
    ca-certificates \
    iptables \
    openssh-server

RUN mkdir -p /var/run/sshd

RUN adduser --quiet jenkins
RUN echo "jenkins:jenkins" | chpasswd
RUN echo "jenkins ALL=(ALL) NOPASSWD: ALL" > /etc/sudoers.d/jenkins

# Install Docker from Docker Inc. repositories.
RUN echo deb https://apt.dockerproject.org/repo ubuntu-trusty main > /etc/apt/sources.list.d/docker.list \
  && apt-key adv --keyserver hkp://pgp.mit.edu:80 --recv-keys 58118E89F3A912897C070ADBF76221572C52609D \
  && apt-get update -qq \
  && apt-get install -qqy docker-engine

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

RUN apt-get install -y --no-install-recommends openjdk-7-jdk

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

RUN ( sleep 5 && while [ 1 ]; do sleep 1; echo y; done ) | android update sdk -u --filter build-tools-22.0.1; \
( sleep 5 && while [ 1 ]; do sleep 1; echo y; done ) | android update sdk -u --filter 2; \
( sleep 5 && while [ 1 ]; do sleep 1; echo y; done ) | android update sdk -u --filter extra-google-m2repository

RUN apt-get install -y --no-install-recommends g++-multilib lib32z1 lib32stdc++6

RUN chmod +x /usr/local/bin/android-sdk/tools/android

# Define additional metadata for our image.
VOLUME /var/lib/docker
EXPOSE 22 2375

CMD ["/usr/local/bin/entrypoint.sh"]
