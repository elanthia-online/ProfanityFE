# ProfanityFE
A terminal frontend for Simutronics games based on Ruby and Ncurses.

## Installation
1. Install Ruby on machine
2. Git Clone the Lich5 repository
3. Git Clone the ProfanityFE repository
4. Configure the template file for your character in the ProfanityFE\templates folder, otherwise use default.xml
5. Open Lich5 and save a character entry, alternatively do this on another machine with a GUI interface and copy Lich5\data\entry.dat
6. Launch Lich5 via `ruby ~/lich-5/lich.rbw --login Rinualdo --without-frontend --detachable-client=8000 &` or similar.
7. Launch Profanity via `ruby ~/ProfanityFE/profanity.rb --port=8000 --char=Rinualdo`

## Profanity CLI Options
* --port=<port>
* --default-color-id=<id>
* --default-background-color-id=<id>
* --custom-colors=<on|off>
* --settings-file=<filename>
* --char=<character>
* --no-status                           do not redraw the process title with status updates
* --links                               enable links to be shown by default, otherwise can enable via .links command
* --speech-ts                           display timestamps on speech, familiar and thought window
* --remote-url                          display LaunchURLs on screen, used for remote environments
* --template=<filename.xml>             filename of template to use in templates subdirectory

## Sample Scripts
Here's a sample login script written for Linux, usage syntax would be `.\gemstone.sh <CHARNAME>`

Do note that some of these settings will need to be adjusted based on the terminal being used (e.g. xterm-256color vs screen-256color)
```bash
#!/bin/bash
set -e

port=8000
CHAR=$1
LICH_BIN=~/lich-5/lich.rbw
PROFANITY_BIN=~/ProfanityFE/profanity.rb

export TERM=screen-256color

lookup_char_port () {
  local char=$1
  port=$(ps a | egrep -0 "\-\-login $char \-\-detachable-client=([0-9]+)" | egrep -o "[0-9]+" | sort | tail -n1)
}

if [[ -z $CHAR ]]; then
  echo "Usage: gemstone.sh {{character_name}}"
  exit
fi

if [[ -z $DISPLAY ]]; then
  echo "Detected empty DISPLAY setting, defaulting to :0"
fi

echo "Attempting to login as $CHAR..."

if ps aux | \grep [l]ich | \grep -i $CHAR; then
  lookup_char_port $CHAR
  echo "Detecting existing connection on port $port"
else
  if ps a | \grep [d]etachable-client; then
    max_port=$(ps a | grep -Eo "\-\-detachable-client=([0-9]+)" | egrep -o "[0-9]+" | sort | tail -n1)
    port=$(expr $max_port + 1)
  fi
  echo "Detecting existing clients but no connection for this character. Using Port[$port]"
  echo "ruby $LICH_BIN --login $CHAR --detachable-client=$port --without-frontend 2> /dev/null &"
  
  ruby $LICH_BIN --login $CHAR --detachable-client=$port --without-frontend 2> /dev/null &
  sleep 4
fi

for i in {1..10}; do
  echo "Attempting to connect to lich process... "
  echo "ruby $PROFANITY_BIN --port=$port --char=$CHAR"
  if ruby $PROFANITY_BIN --port=$port --char=$CHAR; then
    echo "Done"
    break
  else
    echo "Failed to establish connection, trying again in 3 seconds..."
    sleep 3
  fi
done
```
