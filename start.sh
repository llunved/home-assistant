#!/bin/bash

cd /hass
source bin/activate
exec bin/python3 -m homeassistant --config /etc/homeassistant --log-file /var/lib/homeassistant/home-assistant.log

