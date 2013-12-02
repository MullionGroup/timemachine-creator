#!/usr/bin/env ruby

# Next steps:
# Caching
#   fix tmpfile
# Implement format
# Implement BoundsLTRB
# Figure out mp4 seek problem with ffmpeg

# Full world: http://localhost/cgi-bin/thumbnail?root=http%3A%2F%2Fearthengine.google.org%2Ftimelapse%2Fdata%2F20130507&boundsNWSE=85.051128,-180,-85.051128,180&height=100&frameTime=0

# Northern hemisphere: http://localhost/cgi-bin/thumbnail?root=http%3A%2F%2Fearthengine.google.org%2Ftimelapse%2Fdata%2F20130507&boundsNWSE=85.051128,-180,0,180&height=100&frameTime=0

# Southern hemisphere: http://localhost/cgi-bin/thumbnail?root=http%3A%2F%2Fearthengine.google.org%2Ftimelapse%2Fdata%2F20130507&boundsNWSE=0,-180,-85.051128,180&height=100&frameTime=0

# Rondonia http://localhost/cgi-bin/thumbnail?root=http%3A%2F%2Fearthengine.google.org%2Ftimelapse%2Fdata%2F20130507&boundsNWSE=-8.02999,-65.51147,-13.56390,-59.90845&width=200&frameTime=2.8

# Cache design:
#   Hash URL using 
require 'json'
require 'cgi'
require 'open-uri'
require 'digest'
require 'fileutils'
load File.dirname(File.readlink(__FILE__)) + '/mercator.rb'
load File.dirname(File.readlink(__FILE__)) + '/point.rb'
load File.dirname(File.readlink(__FILE__)) + '/bounds.rb'

cache_dir = "/Users/rsargent/tmp/thumbnail-server-cache"
ffmpeg_path = "#{File.dirname(File.dirname(File.readlink(__FILE__)))}/tilestacktool/ffmpeg/osx/ffmpeg"

cgi = CGI.new

debug = []

begin
  debug << "<html><body>"
  debug << "<pre>"
  debug << JSON.pretty_generate(ENV.to_hash)
  debug << "</pre><hr><pre>"
  debug << JSON.pretty_generate(cgi.params)
  debug << "</pre>"
  debug << "<hr>"
  
  root = cgi.params['root'][0] or raise "Missing 'root' param"
  root = root.sub(/\/$/, '')
  debug << "root: #{root}<br>"

  format = cgi.params['format'][0] || 'jpg'

  hash = Digest::SHA512.hexdigest(ENV['QUERY_STRING'])
  
  cache_file = "#{cache_dir}/#{hash[0...3]}/#{hash}.#{format}"
  if File.exists?(cache_file)
    STDERR.puts "Found in cache."
    debug << "Found in cache."
  else
    STDERR.puts "Not found in cache; computing"
    #
    # Fetch tm.json
    #
    
    tm_url = "#{root}/tm.json"
    debug << "tm_url: #{tm_url}<br>"
    tm = open(tm_url) {|i| JSON.parse(i.read)}
    debug << JSON.dump(tm)
    debug << "<hr>"
    
    # Use first dataset if there are multiple
    dataset = tm['datasets'][0]
    
    #
    # Fetch r.json
    #
    
    r_url = "#{root}/#{dataset['id']}/r.json"
    debug << "r_url: #{r_url}<br>"
    r = open(r_url) {|i| JSON.parse(i.read)}
    debug << JSON.dump(r)
    debug << "<br>"
    
    #
    # Parse bounds
    #
    
    # TODO(rsargent): parse coordinates
    timemachine_width = r['width']
    timemachine_height = r['height']
    debug << "timemachine dims: #{timemachine_width} x #{timemachine_height}<br>"
    
    projection_bounds = tm['projection-bounds'] or raise "#{tm_url} missing projection-bounds"
    projection = MercatorProjection.new(projection_bounds, timemachine_width, timemachine_height)
    debug << "projection-bounds: #{JSON.dump(projection_bounds)}<br>"
    
    boundsNWSE = cgi.params['boundsNWSE'][0].split(',').map{|x| x.to_f}
    boundsNWSE.size == 4 or raise "boundsNWSE must be specified and have 4 coords separated by commas"
    debug << "boundsNWSE: #{boundsNWSE.join(', ')}<br>"
    ne = projection.latlngToPoint({'lat' => boundsNWSE[0], 'lng' => boundsNWSE[1]})
    sw = projection.latlngToPoint({'lat' => boundsNWSE[2], 'lng' => boundsNWSE[3]})
    
    
    bounds = Bounds.new(Point.new(ne['x'], ne['y']), Point.new(sw['x'], sw['y']))
    input_aspect_ratio = bounds.size.x.to_f / bounds.size.y
    
    debug << "bounds: #{bounds}<br>"
    
    #
    # Requested output size
    #
    
    output_width = cgi.params['width'][0]
    output_width &&= output_width.to_f
    output_height = cgi.params['height'][0]
    output_height &&= output_height.to_f
    
    if !output_width && !output_height
      raise "Must specify at least one of 'width' and 'height'"
    elsif output_width && output_height
      #
      # output aspect ratio was specified.  Tweak input bounds to match output aspect ratio, by selecting
      # new bounds with the same center and area as original.
      #
      output_aspect_ratio = output_width.to_f / output_height
      aspect_factor = Math.sqrt(output_aspect_ratio / input_aspect_ratio)
      bounds = Bounds.with_center(bounds.center, 
                                  Point.new(bounds.size.x * aspect_factor, bounds.size.y / aspect_factor))
    elsif output_width
      output_height = (output_width / input_aspect_ratio).round
    else
      output_width = (output_height * input_aspect_ratio).round
    end
    
    #
    # Search for tile
    #
    
    tile_url = crop = nil
    
    tile_spacing = Point.new(r['tile_width'], r['tile_height'])
    video_size = Point.new(r['video_width'], r['video_height'])
    
    r['nlevels'].times do |i|
      subsample = 1 << i
      tile_coord = (bounds.min / subsample / tile_spacing).floor
      level = r['nlevels'] - i - 1
      
      tile_bounds = Bounds.new(tile_coord * tile_spacing * subsample,
                               (tile_coord * tile_spacing + video_size) * subsample)
      
      tile_url = "#{root}/#{dataset['id']}/#{level}/#{tile_coord.y}/#{tile_coord.x}.webm"
      debug << "subsample #{subsample}, tile #{tile_bounds} #{tile_url} contains #{bounds}? #{tile_bounds.contains bounds}<br>"
      if tile_bounds.contains bounds
        crop = (bounds - tile_bounds.min) / subsample
        debug << "Best tile: #{tile_coord}, level: #{level} (subsample: #{subsample})<br>"
        debug << "Tile url: #{tile_url}<br>"
        debug << "Tile crop: #{crop}<br>"
        break
      end
    end
    crop or raise "Didn't find containing tile"
    
    #
    # Construct ffmpeg invocation
    #
    
    # frameTime defaults to 0
    time = cgi.params['frameTime'][0] || 0

    tmpfile = "#{cache_file}.tmp-#{Process.pid}.#{format}"
    FileUtils.mkdir_p(File.dirname(tmpfile))
    
    cmd = "#{ffmpeg_path} -y -ss #{time} -i #{tile_url} -vf 'crop=#{crop.size.x}:#{crop.size.y}:#{crop.min.x}:#{crop.min.y},scale=#{output_width}:#{output_height}' -vframes 1 -qscale 2 '#{tmpfile}'"
    
    debug << "Running: '#{cmd}'<br>"
    system(cmd) or raise "Error executing '#{cmd}'"
    File.rename tmpfile, cache_file
    
    #
    # Done
    #
  end
    
  debug_mode = cgi.params.has_key? 'debug'
  
  if debug_mode
    debug << "</body></html>"
    cgi.out {debug.join('')}
  else
    mime_types = {
      'jpg' => 'image/jpeg',
      'png' => 'image/png'
    }
    image = open(cache_file) {|i| i.read}
    cgi.out("type"=> mime_types[format]) {image}
  end
  
rescue Exception => e
  debug.insert 0, "400: Bad Request<br>"
  debug.insert 2, "<pre>#{e}\n#{e.backtrace.join("\n")}</pre>"
  debug.insert 3, "<hr>"
  cgi.out("status" => "BAD_REQUEST") {debug.join('')}
end
