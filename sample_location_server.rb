#!/usr/bin/ruby1.8
#
# Capture events from Meraki CMX Location Push API, Version 1.0.
#
# NOTE: This code is for sample purposes only. Before running in production,
# you should probably add SSL/TLS support by running this server behind a
# TLS-capable reverse proxy like nginx. You should also test that your server
# is capable of handling the rate of events that will be generated by your
# networks.
#
# To use this webapp:
#
#   - Ensure you have ruby 1.8 installed
#   - Ensure that you have the sinatra gem installed; if you don't, do
#       gem install sinatra
#   - Ensure that you have the data_mapper gem installed; if you don't, do
#       gem install data_mapper
#
# Let's say you plan to run this server on a host called pushapi.example.com.
# Go to Meraki's Dashboard and configure the CMX Location Push API with the url
# "http://pushapi.example.com:4567/events", choose a secret, and make note of
# the validation code that Dashboard provides. Pass the secret and validation
# code to this server when you start it:
#
#   sample_location_server.rb <secret> <validator>
#
# You can change the bind interface (default 0.0.0.0) and port (default 4567)
# using Sinatra's -o and -p option flags:
#
#   sample_location_server.rb -o <interface> -p <port> <secret> <validator>
#
# Now click the "Validate server" link in CMX Location Push API configuration in
# Dashboard. Meraki's servers will perform a get to this server, and you will
# see a log message like this:
#
#   [26/Mar/2013 11:52:09] "GET /events HTTP/1.1" 200 6 0.0024
#
# If you do not see such a log message, check your firewall and make sure
# you're allowing connections to port 4567. You can confirm that the server
# is receiving connections on the port using
#
#   telnet pushapi.example.com 4567
#
# Once Dashboard has confirmed that the URL you provided returns the expected
# validation code, it will begin posting events to your URL. For example, when
# a client probes one of your access points, you'll see a log message like
# this:
#
#   [2013-03-26T11:51:57.920806 #25266]  INFO -- : client aa:bb:cc:dd:ee:ff
#     seen on ap 11:22:33:44:55:66 with rssi 24 on Tue Mar 26 11:50:31.836 UTC
#     2013 at (37.703678, -122.45089)
#
# After your first client pushes start arriving (this may take a minute or two),
# you can get a JSON blob describing the last client probe using:
#
#   pushapi.example.com:4567/clients/{mac}
#
# where {mac} is the client mac address. For example,
#
#   http://pushapi.example.com:4567/clients/34:23:ba:a6:75:70
#
# may return
#
#   {"id":65,"mac":"34:23:ba:a6:75:70","seenAt":"Fri Apr 18 00:01:41.479 UTC 2014",
#   "lat":37.77059042088197,"lng":-122.38703445525945}
#
# You can also view the sample frontend at
#
#   http://pushapi.example.com:4567/
#
# Try connecting your mobile to your network, and entering your mobile's WiFi MAC in
# the frontend.

require 'rubygems'
require 'sinatra'
require 'data_mapper'
require 'json'

# ---- Parse command-line arguments ----

if ARGV.size < 2
  # The sinatra gem parses the -o and -p options for us.
  puts "usage: sample_push_api_server.rb [-o <addr>] [-p <port>] <secret> <validator>"
  exit 1
end

SECRET = ARGV[-2]
VALIDATOR = ARGV[-1]

# ---- Set up the database -------------

DataMapper.setup(:default, "sqlite:memory:")

class Client
  include DataMapper::Resource

  property :id,         Serial                    # row key
  property :mac,        String,  :key => true
  property :seenString, String
  property :seenMillis, Integer, :default => 0
  property :lat,        Float
  property :lng,        Float
  property :unc,        Float
  property :nSamples,   Integer
end

DataMapper.finalize

DataMapper.auto_migrate!    # Creates your schema in the database

# ---- Set up routes -------------------

# Serve the frontend.
get '/' do
  send_file File.join(settings.public_folder, 'index.html')
end

# This is used by the Meraki API to validate this web app.
# In general it is a Bad Thing to change this.
get '/events' do
  VALIDATOR
end

# Respond to Meraki's push events. Here we're just going
# to write the most recent events to our database.
post '/events' do
  map = JSON.parse(params[:data])
  if map['secret'] != SECRET
    logger.warn "got post with bad secret: #{SECRET}"
    return
  end
  map['probing'].each do |c|
    loc = c['location']
    if loc != nil
      cmac = c['client_mac']
      lat = loc['lat']
      lng = loc['lng']
      seenString = c['last_seen']
      seenMillis = c['last_seen_millis']
      logger.info "client #{cmac} seen on ap #{c['ap_mac']} with rssi #{c['rssi']} on #{seenString} (#{seenMillis}) at (#{lat}, #{lng}})"
      @client = Client.first_or_create(:mac => cmac)
      if (seenMillis > @client.seenMillis)
        @client.attributes = { :lat => lat, :lng => lng, 
                               :seenString => seenString, :seenMillis => seenMillis,
                               :unc => loc['unc'], :nSamples => loc['nSamples'] }
        @client.save
      elsif (@client.seenMillis == 0)
        Client.delete(:mac => cmac)
      end
    end
  end
  ""
end

# Serve client data from the database.

# This matches
#    /clients/<mac>
# and returns a client with a given mac address, or empty JSON
# if the mac is not in the database.
get '/clients/:mac' do |m|
  @client = Client.first(:mac => m.downcase)  # Lowercase in case someone entered capital hex
  logger.info("Retrieved client #{@client}")
  if @client == nil
    "{}"
  else
    JSON.generate(@client)
  end
end

# This matches
#   /clients OR /clients/
# and returns a JSON blob of all clients.
get %r{/clients/?} do
  clients = Client.all
  JSON.generate(clients)
end