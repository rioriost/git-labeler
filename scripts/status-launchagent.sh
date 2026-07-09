#!/bin/sh
set -eu

label="st.rio.git-labeler"
uid="$(id -u)"

launchctl print "gui/${uid}/${label}"
