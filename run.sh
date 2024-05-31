#!/usr/bin/env bash

BASE_URL="https://geo.irceline.be/sos"
TS_DELAY="30 minutes ago"

IS_SILENT=true
PUBLISH_HA_DISCOVERY=true
MQTT_TOPIC_PREFIX="irceline/"


STATIONS_LIST=":linkeroever:rieme:uccle:moerkerke:idegem:gent:gent_carlierlaan:gent_lange_violettestraat:destelbergen:wondelgem:evergem:sint_kruiswinkel:zelzate:wachtebeke:"

log() {
  if [ "$IS_SILENT" = false ];
  then
    echo $1
  fi
}

mqtt_publish() {
  topic=$1
  payload=$2  
  mosquitto_pub --username "$MQTT_USER" --pw "$MQTT_PASSWORD" --retain -t "$topic" -m "$payload"
}

mqtt_publish_ha_discovery() {
  station=$1
  phenomenon=$2
  unit_of_measurement=$3
  device_class=$4

  global_sensor_prefix=${MQTT_TOPIC_PREFIX%/}
  
  topic="homeassistant/sensor/${global_sensor_prefix}_${station}_${phenomenon}/config"

  payload=$(cat <<PLEOL
  {
    "device": {
      "name": "${MQTT_TOPIC_PREFIX}${station}/${phenomenon}",
      "identifiers": ["${global_sensor_prefix}_${station}_${phenomenon}"]
    },
    "object_id": "${MQTT_TOPIC_PREFIX}${station}/${phenomenon}",
    "state_topic": "${MQTT_TOPIC_PREFIX}${station}/${phenomenon}",
    "state_class": "measurement",
    "json_attributes_topic": "${MQTT_TOPIC_PREFIX}${station}/${phenomenon}",
    "unit_of_measurement": "${unit}",
    "device_class": "${device_class}",
    "value_template": "{{ value_json.${phenomenon} }}"
  }
PLEOL
  )

  mqtt_publish "$topic" "$payload"
}

mqtt_publish_state() {
  station=$1
  phenomenon=$2
  value=$3
  timestamp=$4
  latitude=$5
  longitude=$6

  topic="${MQTT_TOPIC_PREFIX}${station}/${phenomenon}"
  payload=$(cat <<PLEOL
  {
    "${phenomenon}": ${value},
    "timestamp": "${timestamp}",
    "latitude": ${latitude},
    "longitude": ${longitude}
  }
PLEOL
  )

  mqtt_publish "$topic" "$payload"
}

normalize_phenomenon() {
  phenomenon=$1
  phenomenon_normalized=`echo ${phenomenon,,} | sed 's/particulate matter < 10 µm/pm10/' | sed 's/particulate matter < 2.5 µm/pm25/' | sed 's/particulate matter < 1 µm/pm1/' | sed 's/ /_/g' | sed 's/(//g' | sed 's/)//g' `  
  if [ "$phenomenon_normalized" = "relative_humidity" ];
  then
    phenomenon_normalized="humidity"
  fi

  echo $phenomenon_normalized
}

phenomenon_to_unit() {
  phenomenon=$1
  unit="µg/m³"

  if [ "$phenomenon" = "temperature" ];
  then
    unit="°C"
  elif [ "$phenomenon" = "humidity" ];
  then
    unit="%"
  elif [ "$phenomenon" = "atmospheric_pressure" ];
  then
    unit="mbar"
  elif [ "$phenomenon" = "carbon_monoxide" ];
  then
    unit="ppm"
  elif [ "$phenomenon" = "carbon_dioxide" ];
  then
    unit="ppm"
  fi

  echo $unit
}

phenomenon_to_device_class() {
  phenomenon=$1
  device_class_list=":date:enum:timestamp:apparent_power:aqi:atmospheric_pressure:battery:carbon_monoxide:carbon_dioxide:current:data_rate:data_size:distance:duration:energy:energy_storage:frequency:gas:humidity:illuminance:irradiance:moisture:monetary:nitrogen_dioxide:nitrogen_monoxide:nitrous_oxide:ozone:ph:pm1:pm10:pm25:power_factor:power:precipitation:precipitation_intensity:pressure:reactive_power:signal_strength:sound_pressure:speed:sulphur_dioxide:temperature:volatile_organic_compounds:volatile_organic_compounds_parts:voltage:volume:volume_storage:water:weight:wind_speed:"
  device_class=""
  
  if [[ ":$device_class_list:" = *:$phenomenon:* ]];    
  then 
    device_class="${phenomenon}"      
  fi


  echo $device_class
}

label_to_location() {
  label=$1
  location=`echo $label | sed 's/ - /|/' | cut -d'|' -f2 | xargs`
  echo $location
}

label_to_location_id() {
  label=$1
  location_id=`echo ${label,,} | sed 's/ - /|/' | cut -d'|' -f1 | xargs`
  echo $location_id
}

location_to_station() {
  location=$1
  station=`echo ${location,,} | sed 's/ /_/g' | sed 's/-/_/g' | sed 's/(//g' | sed 's/)//g' ` 
  echo $station
}


stations_request=`curl \
  -H "Content-Type: application/json" \
  -X GET \
  --silent \
  --data-urlencode "near=$bbox" \
  "$BASE_URL/api/v1/stations?expanded=true"`

by_station=`echo $stations_request | jq -c '.[] | {properties, geometry}' `


IFS=$'\n'
for i in $by_station;
do
  label=`echo $i | jq -r '.properties.label'`
  longitude=`echo $i | jq -r '.geometry.coordinates | .[0]'`
  latitude=`echo $i | jq -r '.geometry.coordinates | .[1]'`

  location=`label_to_location $label`
  location_id=`label_to_location_id $label`
  station=`location_to_station $location`
  timeseries=`echo $i | jq -r '.properties.timeseries | to_entries | map(.key)'`

  if [[ ":$STATIONS_LIST:" = *:$station:* ]]
  then    
    true
  else
    continue    
  fi

  log "$location $location_id: ($station) $latitude,$longitude"
  timespan="PT0H/$(date -d $TS_DELAY --utc +"%Y-%m-%dT%H:00:00Z")"

  timeseries_values=`curl -H "Content-Type: application/json" -X POST --silent --json "{\"timeseries\":$timeseries, \"timespan\":\"$timespan\"}" "$BASE_URL/api/v1/timeseries/getData"`
  #echo $timeseries_values

  
  for ts in `echo $i | jq -c '.properties.timeseries | to_entries | .[]'`
  do
    ts_id=`echo $ts | jq -r '.key'`    
    phenomenon=`echo $ts | jq -r '.value.phenomenon.label'`
    phenomenon_normalized=$(normalize_phenomenon $phenomenon)
    device_class=$(phenomenon_to_device_class $phenomenon_normalized)
    unit=$(phenomenon_to_unit $phenomenon_normalized)

    ts_value=`echo $timeseries_values | jq -r '.["'$ts_id'"]["values"][0].value'`
    if [ "$ts_value" = "null" ];
    then
      #echo "$ts_id $phenomenon_normalized has no value" > /dev/stderr
      continue
    fi
    ts_timestamp=`echo $timeseries_values | jq -r '.["'$ts_id'"]["values"][0].timestamp'`
    ts_datetime=`date -d @$((ts_timestamp / 1000)) --utc +"%Y-%m-%dT%H:%M:%SZ"`

    #echo $ts
    #log "  $ts_id $phenomenon_normalized $ts_value $unit at $ts_datetime"
    mqtt_publish_ha_discovery $station $phenomenon_normalized $unit $device_class
    mqtt_publish_state $station $phenomenon_normalized $ts_value $ts_datetime $latitude $longitude

    
  #attributes.latitude = ''${latitude}'';
  #attributes.longitude = ''${longitude}'';
  #attributes.last_updated = ''{{ ((value_json["${ts_id}"]["values"][0]["timestamp"] | float) / 1000) | timestamp_custom('%Y:%m:%dT%H:%M:%SZ') }}'';

  done

  
done
