#!/bin/bash
array=( low mid high )
for i in "${array[@]}"
do
	mkdir $i
	sed -e "s/###PRIO###/$i/g" Dockerfile.tmp > $i/Dockerfile
	docker rmi "${i}prio"
	docker build -t "${i}prio" $i
done
