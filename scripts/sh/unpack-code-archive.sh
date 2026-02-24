#!/bin/bash
ROOT=/f/repos/temp/domain.dx.domain
awk '
  /BEGIN FILE:/ {
    file = 
    gsub("=", "", file)
    sub("\{ROOT\}", ENVIRON["ROOT"], file)
    print "" > file
    inFile=1
    next
  }
  /END FILE:/ { inFile=0; next }
  inFile==1 { print bash >> file }
' /f/tmp/full_application_dump.txt
