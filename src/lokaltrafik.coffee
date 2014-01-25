# Description:
#   Get travel information via Resrobot (http://www.trafiklab.se/api/resrobot-sok-resa)
#
# Dependencies:
#   "rsvp" : "*"
#   "momemt" : "*"
#
# Configuration:
#   HUBOT_RESROBOT_KEY - An API key for http://www.trafiklab.se/api/resrobot-sok-resa
#
# Commands:
#   hubot travel to Spånga station from Stockholm centrallocation at 12:00 via train
#   hubot travel to Spånga station from Stockholms centralstation in 20 minutes
#   hubot travel from Spånga station (via [bus|train])? - Shows a list of departures
#
# Author:
#   Tommy Brunn (http://github.com/Nevon)

rsvp = require "rsvp"
moment = require "moment"

class Locations
  constructor: (@robot, @key) ->
    @cache = []
    @base_url = "https://api.trafiklab.se/samtrafiken/resrobot/FindLocation.json"
    @api_version = "2.1"
    @coord_sys = "RT90"

    @robot.brain.on 'loaded', =>
      locations_from_brain = @robot.brain.data.locations
      # only overwrite the cache from redis if data exists in redis
      if locations_from_brain
        @cache = locations_from_brain

  add: (location) ->
    location.added = new Date()
    @cache.push location
    @robot.brain.data.locations = @cache

  delete: (location_id) ->
    result = []
    @cache.forEach (location) ->
      if location.locationid isnt location_id
        result.push location

    @cache = result
    @robot.brain.data.locations = @cache

  get: (display_name) ->
    result = null
    self = @
    new rsvp.Promise (resolve, reject) ->
      http_request = self.robot.http(self.base_url + "?key=" + self.key + "&apiVersion=" + self.api_version + "&coordSys=" + self.coord_sys + "&from=" + display_name)
      
      http_request.get() (err, res, body) ->
        if err
          console.log("Error!", err)
          reject err
        else
          result = JSON.parse(body)

          if !result.findlocationresult.from.location or result.findlocationresult.from.location.length == 0
            console.log("Zero length result", result)
            reject result

          result.findlocationresult.from.location.forEach (location) ->
            if location.bestmatch
              self.add location
              console.log("Got location from API")
              resolve location

class Search
  constructor: (@robot, @key) ->
    @cache = []
    @base_url = "https://api.trafiklab.se/samtrafiken/resrobotsuper/Search.json"
    @api_version = "2.1"
    @coord_sys = "RT90"

  getFrom: (from, time, disabled_modes) ->
    return

  getFromTo: (from, to, disabled_modes, at_time, in_minutes) ->
    result = null
    self = @
    return new rsvp.Promise (resolve, reject) ->
      request_string = self.base_url + "?key=" + self.key + "&apiVersion=" + self.api_version + "&coordSys=" + self.coord_sys
      request_string += "&fromId=#{from.locationid}"
      request_string += "&from=#{from.displayname}"
      request_string += "&toId=#{to.locationid}"
      request_string += "&to=#{to.displayname}"

      if at_time
        request_string += "&time=#{at_time}"
      else if in_minutes
        travel_time = moment.add("minutes", in_minutes).format("HH:mm")
        request_string += "&time=#{travel_time}"

      disabled_modes.forEach (mode) ->
        request_string += "&#{mode}=false"

      console.log("Request string: #{request_string}")

      http_request = self.robot.http(request_string)
      
      http_request.get() (err, res, body) ->
        if err
          reject err
        else
          console.log("RESPONSE BODY =====")
          console.log(body)
          console.log("RESPONSE BODY =====")
          resolve JSON.parse(body)


module.exports = (robot) ->
  KEY = process.env.HUBOT_RESROBOT_KEY

  locations = new Locations robot, KEY
  search = new Search robot, KEY

  # A set of transportation modes. Each mode represents a number of options. Each mode that is sent to the
  # server disables that mode. So for example, "train" will disable buses, boats and express buses
  modes = {
    "train" : ["mode3", "mode4", "mode5"],
    "subway" : ["mode3", "mode4", "mode5"],
    "bus" : ["mode1", "mode2", "mode4"],
    "boat" : ["mode1", "mode2", "mode3", "mode5"]
  }

  disabled_modes = []

  formatTimeTableResult = (travel_options) ->
    outString = ""
    i = 1
    travel_options.ttitem.forEach (travel) ->
      console.log("Travel: ", travel);
      outString += "#{i}. Leave from #{travel.segment[0].departure.location.name} (#{moment(travel.segment[0].departure.datetime).format("HH:mm")}) and arrive at #{travel.segment[travel.segment.length-1].arrival.location.name} (#{moment(travel.segment[travel.segment.length-1].arrival.datetime).format("HH:mm")})\n"
      # Each travel
      travel.segment.forEach (segment) ->
        # Each segment in that travel
        console.log("Segment: ", segment)
        outString += "    #{segment.segmentid.mot["#text"]} from #{segment.departure.location.name} leaves for #{segment.direction} at #{moment(segment.departure.datetime).format("HH:mm")}, arrives at #{segment.arrival.location.name} at #{moment(segment.arrival.datetime).format("HH:mm")}\n"
      i++
    return outString

  robot.respond /travel (.+)/i, (msg) ->
    input = msg.match[1]
    location_from = false
    location_to = false
    transportation_mode = false
    departure_time = moment().add("minutes", 10).format("HH:mm")
    promises = []

    try
      from = input.match(/from (.*?(?=[\s]to[\s]|[\s]by[\s]|[\s]at[\s]|[\s]in[\s]|[\s]by[\s]|$))/i)[1]
    catch e
      return

    try
      to = input.match(/to (.*?(?=[\s]from[\s]|[\s]by[\s]|[\s]at[\s]|[\s]in[\s]|[\s]via[\s]|$))/i)[1]
    catch e
      to = false

    try
      via = input.match(/(?:by|via) (train|subway|bus)/i)[1]
    catch e
      via = false

    console.log("from: ", from)
    console.log("to: ", to)
    console.log("via: ", via)

    if from
      promises.push(locations.get from)

    if to
      promises.push(locations.get to)
      

    rsvp.all(promises).then (response) ->
      console.log("Promises fulfilled", response)
      location_from = response[0]
      location_to = response[1]

      search_promise = search.getFromTo location_from, location_to, disabled_modes, departure_time
      search_promise.then (response) ->
        msg.send formatTimeTableResult response.timetableresult
      .then null, (err) ->
        console.log("Search failed: ", err)
    .then null, (err) ->
      console.log("Things went to shit", err)

    # if location_from and location_to
    #   msg.send search.getFromTo(location_from, location_to, disabled_modes)