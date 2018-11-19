#!/bin/bash

# get all filename in specified path
path=$1
files=$(ls $path)
for filename in $files
do
 echo "The file is $filename"
 grep 8898 $path$filename
 if [ $? != 0 ];then
    echo "port 8898 does not exist"
    exit 1;
 fi
 links=$(grep 8898 $path$filename|awk -F " " '{print $2}') 
 for link in $links
 do 
  wget $link
  if [ $? != 0 ];then
    echo "wget failed"
    exit 1;
  else
    echo "wget $link succeed"
  fi
 done  
done
