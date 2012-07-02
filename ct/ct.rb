#!/usr/bin/env ruby

# You need the xml-simple gem to run this script
# [sudo] gem install xml-simple

# Ruby standard modules
require 'fileutils'
require 'open-uri'
require 'set'
require 'thread'

# Local modules
$LOAD_PATH.unshift(File.expand_path(File.dirname(__FILE__)))
$LOAD_PATH.unshift(File.expand_path(File.dirname(__FILE__)) + "/ctlib")
require 'backports'
require 'image_size'
require 'json'
require 'tile'
require 'tileset'
require 'xmlsimple'

$ajax_includes = {}

def include_ajax(filename, contents)
  $ajax_includes[filename] = contents
end

def include_ajax_file(filename)
  include_ajax filename, Filesystem.read_file("#{$explorer_source_dir}/#{filename}")
end

def javascript_quote x
  # JSON.generate works for arrays and maps, but not strings or numbers.  So wrap in an array
  # before generating, and then take the square brackets off
  JSON.generate([x])[1...-1]
end

def ajax_includes_to_javascript
  statements = ["cached_ajax={};"]
  $ajax_includes.keys.sort.each do |filename|
    statements << "cached_ajax['#{filename}']=#{javascript_quote($ajax_includes[filename])};"
  end
  statements.join "\n\n"
end

#profile = "ct.profile.13n.txt"
profile = false
debug = false
$check_mem = false

class Partial
  def initialize(n, total)
    @n = n
    @total = total
  end

  def self.none
    Partial.new(0,1)
  end

  def self.all
    Partial.new(1,1)
  end

  def none?
    @n == 0
  end

  def all?
    @total == 1 && !none?
  end

  def apply(seq)
    none? and return []
    seq = seq.map
    len = seq.size
    start = len * (@n - 1) / @total
    finish = len * @n / @total
    start...finish
  end
  def to_s
    if none?
      "Skip all"
    elsif all?
      "All"
    else
      "Part #{@n} of #{@total}"
    end
  end
end

$compute_tilestacks = Partial.all
$compute_videos = Partial.all

if profile
  require 'rubygems'
  require 'ruby-prof'
  # RubyProf.measure_mode = RubyProf::MEMORY
  RubyProf.start
end

if $check_mem 
  require 'check-mem'
end

start_time = Time.new

if debug
  require 'ruby-debug'
end

$run_remotely = nil
$run_remotely_json = false
$dry_run = false

if RUBY_VERSION < '1.8.5' || RUBY_VERSION > '1.9.'
  raise "Ruby version is #{RUBY_VERSION}, but must be >= 1.8.6, and must be < 1.9 because of threading bugs in 1.9"
end

if `echo %PATH%`.chomp != '%PATH%'
  $os = 'windows'
elsif File.exists?('/proc')
  $os = 'linux'
else
  $os = 'osx'
end

if $os == 'windows'
  require 'win32/registry'
end

def temp_file_unique_fragment
  "tmp-#{Process.pid}-#{Thread.current.object_id}-#{Time.new.to_i}"
end

def self_test(stitch = true)
  success = true
  STDERR.puts "Testing tilestacktool...\n"
  status = Kernel.system(*(tilestacktool_cmd + ['--selftest']))
  
  if status
    STDERR.puts "tilestacktool: succeeded\n"
  else
    STDERR.puts "tilestacktool: FAILED\n"
    success = false
  end
    
  if stitch
    STDERR.puts "Testing stitch..."
    status = Kernel.system($stitch, '--batch-mode', '--version')
    if status
      STDERR.puts "stitch: succeeded"
    else
      STDERR.puts "stitch: FAILED"
      success = false
    end
  end

  if $explorer_source_dir
    STDERR.puts "Explorer source dir: succeeded"
  else
    STDERR.puts "Explorer source dir not found: FAILED"
  end

  STDERR.puts "ct.rb self-test #{success ? 'succeeded' : 'FAILED'}."
  
  return success
end

def read_from_registry(hkey,subkey)
  begin
    reg_type = Win32::Registry::Constants::KEY_READ | KEY_WOW64_64KEY
    reg = Win32::Registry.open(hkey,subkey,reg_type)
    return reg
  rescue Win32::Registry::Error
    # If we fail to read the key (e.g. it does not exist, we end up here)
    return nil
  end
end

$tilestacktool_args = []

def tilestacktool_cmd 
  [$tilestacktool] + $tilestacktool_args
end  

def stitch_cmd
  cmd = [$stitch]
  cmd << '--batch-mode'
  cmd << '--nolog'
  $os == 'linux' and $run_remotely and cmd << '--xvfb'
  cmd
end

$sourcetypes = {}

class Filesystem
  def self.mkdir_p(path)
    FileUtils.mkdir_p path
  end

  def self.read_file(path)
    open(path, 'r') { |fh| fh.read }
  end

  def self.write_file(path, data)
    open(path, 'w') { |fh| fh.write data }
  end

  def self.cache_directory(root)
  end

  def self.exists?(path)
    File.exists? path
  end
    
  def self.cached_exists?(path)
    File.exists? path
  end

  def self.cp_r(src, dest)
    FileUtils.cp_r src, dest
  end

  def self.cp(src, dest)
    FileUtils.cp src, dest
  end

  def self.mv(src, dest)
    FileUtils.mv src, dest
  end

  def self.rm(path)
    FileUtils.rm_rf Dir.glob("#{path}")
  end

end

def write_json_and_js(path, prefix, obj)
  Filesystem.mkdir_p File.dirname(path)

  js_path = path + '.js'
  Filesystem.write_file(js_path, prefix + '(' + JSON.pretty_generate(obj) + ')')
  STDERR.puts("Wrote #{js_path}")

  # Deprecated.  TODO(RS): Remove this soon
  write_json_path = true

  if write_json_path
    json_path = path + '.json'
    Filesystem.write_file(json_path, JSON.pretty_generate(obj))
    STDERR.puts("Wrote #{json_path}")
  end
end

Dir.glob(File.dirname(__FILE__) + "/*_source.rb").each do |file|
  STDERR.puts "Loading #{File.basename(file)}..."
  require file
end

$verbose = false
@@global_parent = nil

#
# DOCUMENTATION IS IN README_CT.TXT
#

def date
  Time.now.strftime("%Y-%m-%d %H:%M:%S")
end

def usage(msg=nil)
  msg and STDERR.puts msg
  STDERR.puts "usage:"
  STDERR.puts "ct.rb [flags] input.tmc output.timemachine"
  STDERR.puts "Flags:"
  STDERR.puts "-j N:  number of parallel jobs to run (default 1)"
  STDERR.puts "-r N:  max number of rules per job (default 1)"
  STDERR.puts "-v:    verbose"
  STDERR.puts "--remote [script]:  Use script to submit remote jobs"
  STDERR.puts "--remote_json [script]:  Use script to submit remote jobs"
  STDERR.puts "--tilestacktool path: full path of tilestacktool"
  exit 1
end

def without_extension(filename)
  filename[0..-File.extname(filename).size-1]
end

class TemporalFragment
  attr_reader :start_frame, :end_frame, :fragment_seq
  # start_frame and end_frame are both INCLUSIVE
  def initialize(start_frame, end_frame, fragment_seq = nil)
    @start_frame = start_frame
    @end_frame = end_frame
    @fragment_seq = fragment_seq
  end
end  

class VideoTile
  attr_reader :c, :r, :level, :x, :y, :subsample, :fragment
  def initialize(c, r, level, x, y, subsample, fragment)
    @c = c
    @r = r
    @level = level
    @x = x
    @y = y
    @subsample = subsample
    @fragment = fragment
  end

  def path
    ret = "#{@level}/#{@r}/#{@c}"
    @fragment.fragment_seq and ret += "_#{@fragment.fragment_seq}"
    ret
  end

  def to_s
    "#<VideoTile path='#{path}' r=#{@r} c=#{@c} level=#{@level} x=#{@x} y=#{@y} subsample=#{@subsample}>"
  end

  def source_bounds(vid_width, vid_height)
    {'xmin' => @x, 'ymin' => @y, 'width' => vid_width * @subsample, 'height' => vid_height * @subsample}
  end

  def frames
    {'start' => @fragment.start_frame, 'end' => @fragment.end_frame}
  end
end

class Rule
  attr_reader :targets, :dependencies, :commands, :local
  @@all = []
  @@all_targets = Set.new
  @@n = 0
  
  def self.clear_all
    @@all = []
  end
  
  def self.all
    @@all
  end

  def self.has_target?(target)
    @@all_targets.member? target
  end
  
  def array_of_strings?(a)
    a.class == Array && a.all? {|e| e.class == String}
  end

  def initialize(targets, dependencies, commands, options={})
    if $check_mem
      @@n += 1
      if @@n % 10000 == 0
        CheckMem.logvm("Created #{@@n} rules")
      end
    end
    
    if targets.class == String
      targets = [targets]
    end
    commands = commands.map {|cmd| cmd.map {|x| x.class == Hash ? JSON.generate(x) : x.to_s} }
    array_of_strings?(targets) or raise "targets must be an array of pathnames"
    array_of_strings?(dependencies) or raise "dependencies must be an array of pathnames"
    @targets = targets
    @dependencies = dependencies
    @commands = commands
    @@all << self
    targets.each { |target| @@all_targets << target }
  end
  
  def self.add(targets, dependencies, commands, options={})
    Rule.new(targets, dependencies, commands, options).targets
  end

  def self.touch(target, dependencies)
    Rule.add(target, dependencies, [tilestacktool_cmd + ['--createfile', target]], {:local => true})
  end
  
  def to_make
    ret = "#{@targets.join(" ")}: #{@dependencies.join(" ")}\n"
    if @commands.size
      ret += "\t@$(SS) '#{@commands.join(" && ")}'"
    end
    ret
  end
  
  def to_s
    "[Rule: #{targets.join(" ")}]"
  end
end

class VideosetCompiler
  attr_reader :videotype, :vid_width, :vid_height, :overlap_x, :overlap_y, :compression, :label, :fps, :show_frameno, :parent
  attr_reader :id
  @@sizes={
    "large"=>{:vid_size=>[1088,624], :overlap=>[1088/4, 624/4]},
    "small"=>{:vid_size=>[768,432], :overlap=>[768/3, 432/3]}
  }
  @@videotypes={
    "h.264"=>{}
  }

  @@leader_bytes_per_pixel={
    30 => 2701656.0 / (1088 * 624 * 90),
    28 => 2738868.0 / (1088 * 624 * 80),
    26 => 2676000.0 / (1088 * 624 * 70),
    24 => 2556606.0 / (1088 * 624 * 60)
  }
  
  def initialize(parent, settings)
    @parent = parent
    @@global_parent = parent
    @label = settings["label"] || raise("Video settings must include label")

    @videotype = settings["type"] || raise("Video settings must include type")
    
    size = settings["size"] || raise("Video settings must include size")
    @@sizes.member?(size) || raise("Video size must be one of [#{@@sizes.keys.join(", ")}]")
    (@vid_width, @vid_height) = @@sizes[size][:vid_size]
    (@overlap_x, @overlap_y) = @@sizes[size][:overlap]

    (@compression = settings["compression"] || settings["quality"]) or raise "Video settings must include compression"
    @compression = @compression.to_i
    @compression > 0 || raise("Video compression must be > 0")

    @fps = settings["fps"] || raise("Video settings must include fps")
    @fps = @fps.to_f
    @fps > 0 || raise("Video fps must be > 0")

    @show_frameno = settings["show_frameno"]

    @frames_per_fragment = settings["frames_per_fragment"]

    @leader = @frames_per_fragment ? 0 : compute_leader_length

    initialize_videotiles
    initialize_id
  end

  def compute_leader_length
    if not @@leader_bytes_per_pixel.member?(@compression)
      raise "Video compression must be one of [#{@@leader_bytes_per_pixel.keys.join(", ")}]"
    end

    bytes_per_frame = @vid_width * @vid_height * @@leader_bytes_per_pixel[@compression]

    leader_threshold = 1200000
    estimated_video_size = bytes_per_frame * nframes
    if estimated_video_size < leader_threshold
      # No leader needed
      return 0
    end
      
    minimum_leader_length = 2500000
    leader_nframes = minimum_leader_length / bytes_per_frame

    # Round up to nearest multiple of frames per keyframe
    frames_per_keyframe = 10
    leader_nframes = (leader_nframes / frames_per_keyframe).ceil * frames_per_keyframe

    return leader_nframes
  end

  def initialize_id
    tokens = ["crf#{@compression}", "#{@fps.round}fps"]
    (@leader > 0) && tokens << "l#{@leader}"
    tokens << "#{@vid_width}x#{@vid_height}"
    @id = tokens.join('-')
  end

  def nframes
    @parent.source.framenames.size
  end

  def initialize_videotiles
    $compute_videos or return
    # Compute levels
    levels = []
    @levelinfo = []
    subsample = 1
    while true do
      input_width = @vid_width * subsample
      input_height = @vid_height * subsample
      
      levels << {:subsample => subsample, :input_width => input_width, :input_height => input_height}
      
      if input_width >= @parent.source.width and input_height >= @parent.source.height
        break
      end
      subsample *= 2
    end
    
    levels.reverse!
    for level in 0...levels.size do
      levels[level][:level] = level
    end

    if @frames_per_fragment
      @temporal_fragments = (nframes / @frames_per_fragment).floor.times.map do |i|
        TemporalFragment.new(i * @frames_per_fragment, 
                             [(i + 1) * @frames_per_fragment, nframes].min - 1,
                             i)
      end
    else
      @temporal_fragments = [TemporalFragment.new(0, nframes - 1)]
    end
    
    @videotiles = []

    levels.each do |level|
      level_rows = 1+((@parent.source.height - level[:input_height]).to_f / (@overlap_y * level[:subsample])).ceil
      level_rows = [1,level_rows].max
      level_cols = 1+((@parent.source.width - level[:input_width]).to_f / (@overlap_x * level[:subsample])).ceil
      level_cols = [1,level_cols].max
      @levelinfo << {"rows" => level_rows, "cols" => level_cols}
      #puts "** level=#{level[:level]} subsample=#{level[:subsample]} #{level_cols}x#{level_rows}=#{level_cols*level_rows} videos input_width=#{level[:input_width]} input_height=#{level[:input_height]}"

      rows_to_compute = $compute_videos.apply(0...level_rows)
      rows_to_compute.each do |r|
        y = r * @overlap_y * level[:subsample]
        level_cols.times do |c|
          x = c * @overlap_x * level[:subsample]
          @temporal_fragments.each do |fragment|
            @videotiles << VideoTile.new(c, r, level[:level], x, y, level[:subsample], fragment)
          end
        end
      end
    end
  end
  
  def rules(dependencies)
    if not $compute_videos
      STDERR.puts "#{id}: skipping video creation"
      dependencies
    else
      STDERR.puts "#{id}: #{@videotiles.size} videos (#{$compute_videos})"
      @videotiles.flat_map do |vt|
        target = "#{@parent.videosets_dir}/#{id}/#{vt.path}.mp4"
        cmd = tilestacktool_cmd
        cmd << "--create-parent-directories"
        
        cmd << '--path2stack'
        cmd += [@vid_width, @vid_height]
        frames = {'frames' => vt.frames,
                  'bounds' => vt.source_bounds(@vid_width, @vid_height)};
        cmd << JSON.generate(frames)
        cmd << @parent.tilestack_dir
        
        cmd += @parent.video_filter || []
        
        @leader > 0 and cmd += ["--prependleader", @leader]
        
        cmd += ['--writevideo', target, @fps, @compression]
        
        Rule.add(target, dependencies, [cmd])
      end
    end
  end
    
  def info
    ret = {
      "level_info"   => @levelinfo,
      "nlevels"      => @levelinfo.size,
      "level_scale"  => 2,
      "frames"       => nframes,
      "fps"          => @fps,
      "leader"       => @leader,
      "tile_width"   => @overlap_x,
      "tile_height"  => @overlap_y,
      "video_width"  => @vid_width,
      "video_height" => @vid_height,
      "width"        => parent.source.width,
      "height"       => parent.source.height
    }
    @frames_per_fragment and ret['frames_per_fragment']=@frames_per_fragment
    ret
  end

  def write_json
    write_json_and_js("#{@parent.videosets_dir}/#{id}/r", 'org.cmucreatelab.loadVideoset', info)
    include_ajax "./#{id}/r.json", info
  end
end

# Looks for images in one or two levels below dir, and sorts them alphabetically
def find_images_in_directory(dir)
  valid_image_extensions = Set.new [".jpg",".jpeg",".png",".tif",".tiff", ".raw", ".kro"]
  (Dir.glob("#{dir}/*.*")+Dir.glob("#{dir}/*/*.*")).sort.select do |image|
    valid_image_extensions.include? File.extname(image).downcase
  end
end

class ImagesSource
  attr_reader :ids, :width, :height, :tilesize, :tileformat, :subsample, :raw_width, :raw_height
  attr_reader :capture_times, :capture_time_parser, :capture_time_parser_inputs, :framenames

  def initialize(parent, settings)
    @parent = parent
    @@global_parent = parent
    @image_dir="#{@parent.store}/0100-original-images"
    @raw_width = settings["width"]
    @raw_height = settings["height"]
    @subsample = settings["subsample"] || 1
    @images = settings["images"] ? settings["images"].flatten : nil
    @capture_times = settings["capture_times"] ? settings["capture_times"].flatten : nil
    @capture_time_parser = settings["capture_time_parser"] || "/home/rsargent/bin/extract_exif_capturetimes.rb"
    @capture_time_parser_inputs = settings["capture_time_parser_inputs"] || "#{@parent.store}/0100-unstitched/"    
    initialize_images
    initialize_framenames
    @tilesize = settings["tilesize"] || ideal_tilesize(@framenames.size)
    @tileformat = settings["tileformat"] || "kro"
  end

  def ideal_tilesize(nframes)
    # Aim for less than half a gigabyte, but no more than 512
    tilesize = 512
    while tilesize * tilesize * nframes * 3 > 0.5e9
      tilesize /= 2
    end
    tilesize
  end

  def initialize_images
    @images ||= find_images_in_directory(@image_dir)
    @images.empty? and usage "No images specified, and none found in #{@image_dir}"
    @images.map! {|image| File.expand_path(image, @parent.store)}
    @raw = (File.extname(@images[0]).downcase == ".raw")
    initialize_size
  end

  def initialize_size
    if @raw
      @raw_width and @raw_height or usage("Must specify width and height for .raw image source")
      @width = @raw_width
      @height = @raw_height
    else
      open(@images[0], "rb") do |fh|
        (@width, @height)=ImageSize.new(fh).get_size
      end
    end
    @width /= @subsample
    @height /= @subsample
  end
  
  def initialize_framenames
    frames = @images.map {|filename| File.expand_path(without_extension(filename)).split('/')}
    # Remove common prefixes
    while frames[0].length > 1 && frames.map {|x|x[0]}.uniq.length == 1
      frames = frames.map {|x| x[1..-1]}
    end
    @framenames = frames.map {|frame| frame.join('@')}
    @image_framenames = {}
    @framenames.size.times {|i| @image_framenames[@images[i]] = @framenames[i]}
  end
  
  def image_to_tiles_rule(image)
    fn = @image_framenames[image]
    target = "#{@parent.tiles_dir}/#{fn}.data/tiles"
    cmd = tilestacktool_cmd + ['--tilesize', @tilesize, '--image2tiles', target, @tileformat, image]
    Rule.add(target, [image], [cmd])
  end
 
  def tiles_rules
    @images.flat_map {|image| image_to_tiles_rule(image)}
  end

end

$sourcetypes['images'] = ImagesSource;

class GigapanOrgSource
  attr_reader :ids, :width, :height, :tilesize, :tileformat, :framenames, :subsample
  attr_reader :capture_time_parser, :capture_time_parser_inputs
  
  def initialize(parent, settings)
    @parent = parent
    @@global_parent = parent
    @urls = settings["urls"]
    @ids = @urls.map{|url| id_from_url(url)}
    @subsample = settings["subsample"] || 1
    @capture_time_parser = "/home/rsargent/bin/extract_gigapan_capturetimes.rb"
    @capture_time_parser_inputs = "#{@parent.store}/0200-tiles"
    @tileformat = "jpg"
    initialize_dimensions
  end

  def initialize_dimensions
    @tilesize = 256
    
    id = @ids[0]
    api_url = "http://api.gigapan.org/beta/gigapans/#{id}.json"
    gigapan = open(api_url) { |fh| JSON.load(fh) }
    @width = gigapan["width"] or raise "Gigapan #{id} has no width"
    @width = @width.to_i / @subsample
    @height = gigapan["height"] or raise "Gigapan #{id} has no height"
    @height = @height.to_i / @subsample
    @framenames = (0...@ids.size).map {|i| framename(i)}
  end
  
  def framename(i)
    "#{"%06d"%i}-#{@ids[i]}"
  end

  def tiles_rules
    @ids.size.times.flat_map do |i|
      target = "#{@parent.tiles_dir}/#{framename(i)}.data/tiles"
      Rule.add(target, [], [['mirror-gigapan.rb', @ids[i], target]])
    end
  end

  def id_from_url(url)
    url.match(/(\d+)/) {|id| return id[0]}
    raise "Can't find ID in url #{url}"
  end
end    

$sourcetypes['gigapan.org'] = GigapanOrgSource;

class PrestitchedSource
  attr_reader :ids, :width, :height, :tilesize, :tileformat, :framenames, :subsample
  attr_reader :capture_time_parser, :capture_time_parser_inputs
  
  def initialize(parent, settings)
    @parent = parent
    @@global_parent = parent
    @subsample = settings["subsample"] || 1
    @capture_time_parser = "/home/rsargent/bin/extract_gigapan_capturetimes.rb"
    @capture_time_parser_inputs = "#{@parent.store}/0200-tiles"
    initialize_frames
  end

  def initialize_frames
    @framenames = Dir.glob("#{@parent.store}/0200-tiles/*.data").map {|dir| File.basename(without_extension(dir))}.sort

    data = XmlSimple.xml_in("#{@parent.store}/0200-tiles/#{framenames[0]}.data/tiles/r.info")
    @width = 
			data["bounding_box"][0]["bbox"][0]["max"][0]["vector"][0]["elt"][0].to_i -
			data["bounding_box"][0]["bbox"][0]["min"][0]["vector"][0]["elt"][0].to_i
    @height = 
			data["bounding_box"][0]["bbox"][0]["max"][0]["vector"][0]["elt"][1].to_i -
			data["bounding_box"][0]["bbox"][0]["min"][0]["vector"][0]["elt"][1].to_i
    @tilesize = data["tile_size"][0].to_i
    @tileformat = "jpg"

    @width /= @subsample
    @height /= @subsample
  end

  def tiles_rules
    []
  end
end

$sourcetypes['prestitched'] = PrestitchedSource;

class StitchSource
  attr_reader :ids, :width, :height, :tilesize, :tileformat, :framenames, :subsample
  attr_reader :align_to, :stitcher_args, :camera_response_curve, :cols, :rows, :rowfirst
  attr_reader :directory_per_position, :capture_times, :capture_time_parser, :capture_time_parser_inputs
  
  def initialize(parent, settings)
    @parent = parent
    @@global_parent = parent
    @subsample = settings["subsample"] || 1
    @width = settings["width"] || 1
    @height = settings["height"] || 1
    @align_to = settings["align_to"] or raise "Must include align-to"
    settings["align_to_comment"] or raise "Must include align-to-comment"
    @stitcher_args = settings["stitcher_args"] or raise "Must include stitcher args"
    @camera_response_curve = settings["camera_response_curve"]
    if !@camera_response_curve
      response_curve_path = [File.expand_path("#{File.dirname(__FILE__)}/g10.response"),
  			     File.expand_path("#{File.dirname(__FILE__)}/ctlib/g10.response")]
      @camera_response_curve = response_curve_path.find {|file| File.exists? file}
      if !@camera_response_curve
        raise "Can't find camera response curve in search path #{response_curve_path.join(':')}"
      end
    end

    if !File.exists?(@camera_response_curve)
      raise "Camera response curve set to #{@camera_response_curve} but the file doesn't exist"
    end

    @cols = settings["cols"] or raise "Must include cols"
    @rows = settings["rows"] or raise "Must include rows"
    @rowfirst = settings["rowfirst"] || false
    @images = settings["images"]
    @directory_per_position = settings["directory_per_position"] || false
	@capture_times = settings["capture_times"] ? settings["capture_times"].flatten : nil
    @capture_time_parser = "/home/rsargent/bin/extract_gigapan_capturetimes.rb"
    @capture_time_parser_inputs = "#{@parent.store}/0200-tiles"
    initialize_frames
  end

  def find_directories
    Filesystem.cached_exists?("#{@parent.store}/0100-unstitched") or raise "Could not find #{@parent.store}/0100-unstitched"
    dirs = Dir.glob("#{@parent.store}/0100-unstitched/*").sort.select {|dir| File.directory? dir}
    dirs.empty? and raise 'Found no directories in 0100-unstitched'
    dirs
  end
    
  def find_images_dpp
    directories = find_directories
    if @cols * @rows != directories.size
      raise "Found #{directories.size} directories in #{@parent.store}/0100-unstitched, but expected #{@cols}x#{@rows}=#{@cols*@rows}"
    end
    dpp_images = []
    
    directories.each do |dir|
      dpp_images << find_images_in_directory(dir)
      if dpp_images[0].size != dpp_images[-1].size
        raise "Directory #{directories[0]} has #{dpp_images[0].size} images, but directory #{dir} has #{dpp_images[-1].size} images"
      end
    end
    
    dpp_images[0].size.times.map do |i|
      dpp_images.map {|images| images[i]}
    end
  end
  
  def find_images
    directories = find_directories
    @framenames = directories.map {|dir| File.basename(dir)}
    directories.map do |dir|
      images = find_images_in_directory(dir)
      images.size == @rows * @cols or raise "Directory #{dir} has #{images.size} images, but expected #{@cols}x#{@rows}=#{@cols*@rows}"
      images
    end
  end
    
  def initialize_frames
    if @images
      @images.size > 0 or raise "'images' is an empty list"
    elsif @directory_per_position
      @images = find_images_dpp
    else
      @images = find_images
    end
    
    @images.each_with_index do |frame, i|
      if @cols * @rows != frame.size
        raise "Found #{frame.size} images in 'images' index #{i}, but expected #{@cols}x#{@rows}=#{@cols*@rows}"
      end
    end

    @images.map! {|frame| frame.map! {|image| File.expand_path(image, @parent.store)} }

    @framenames ||= @images.size.times.map {|i| '%06d' % i}

    @tilesize = 256
    @tileformat = "jpg"
    
    # Read in .gigapan if it exists and we actually need the dimensions from it
    # 1x1 are the dummy dimensions we feed the json file
    first_gigapan = "#{@parent.store}/0200-tiles/#{framenames[0]}.gigapan"
    if @width == 1 && @height == 1 && File.exist?(first_gigapan)
      data = XmlSimple.xml_in(first_gigapan)
      if data
        notes = data["notes"]
        if notes
          dimensions = notes[0].scan(/\d* x \d*/)
          if dimensions
            dimensions_array = dimensions[0].split(" x ")
            if dimensions_array.size == 2
              @width = dimensions_array[0].to_i
              @height = dimensions_array[1].to_i
            end
          end
        end
      end
    end
    
    @width /= @subsample
    @height /= @subsample
  end

  class Copy
    attr_reader :target
  
    def initialize(target)
      @target = target
    end
  end
  
  def copy(x)
    return Copy.new(x)
  end

  def tiles_rules
    targetsets = []
    @framenames.size.times do |i|
      framename = @framenames[i]
      align_to = []
      copy_master_geometry_exactly = false
      align_to_eval = eval(@align_to)

      if align_to_eval.class == Copy
        if align_to_eval.target != i
          align_to += targetsets[align_to_eval.target]
          copy_master_geometry_exactly = true
        end
      else
        align_to_eval.each do |align_to_index|
          if align_to_index >= i
            raise "align_to for index #{i} yields #{align_to_index}, which >= #{i}"
          end
          if align_to_index >= 0
            align_to += targetsets[align_to_index]
          end
        end
        if align_to == [] && i > 0
          raise "align_to is empty for index #{i} but can only be empty for index 0"
        end
      end
      target_prefix = "#{@parent.store}/0200-tiles/#{framename}"
      cmd = stitch_cmd
      cmd += @rowfirst ? ["--rowfirst", "--ncols", @cols] : ["--nrows", @rows]
      # Stitch 1.x:
      # stitch_cmd << "--license-key AATG-F89N-XPW4-TUBU"
      # Stitch 2.x:
      cmd += ['--license-key', 'ACTG-F8P9-AJY3-6733']
      
      cmd += @stitcher_args.split
      if @camera_response_curve
        cmd += ["--load-camera-response-curve", @camera_response_curve]
      end
      
      suffix = "tmp-#{temp_file_unique_fragment}"

      cmd += ["--save-as", "#{target_prefix}-#{suffix}.gigapan"]
      # Only get files with extensions.  Organizer creates a subdir called "cache",
      # which this pattern will ignore
      images = @images[i]
        
      if images.size != @rows * @cols
        raise "There should be #{@rows}x#{@cols}=#{@rows*@cols} images for frame #{i}, but in fact there are #{images.size}"
      end
      cmd += ["--images"] + images
      if copy_master_geometry_exactly
        cmd << "--copy-master-geometry-exactly"
      end
      align_to.each do |master|
        cmd += ["--master", master]
      end
      cmd << "--stitch-quit"

      targetsets << Rule.add("#{target_prefix}.gigapan", 
                             align_to, 
                             [cmd,
                              ['mv', "#{target_prefix}-#{suffix}.gigapan", "#{target_prefix}.gigapan"],
                              ['mv', "#{target_prefix}-#{suffix}.data", "#{target_prefix}.data"]
                             ])
    end
    targetsets.flatten(1)
  end    
end

$sourcetypes['stitch'] = StitchSource;

class Compiler
  attr_reader :source, :tiles_dir, :raw_tilestack_dir, :tilestack_dir, :videosets_dir, :urls, :store, :video_filter
  attr_reader :id, :versioned_id
  
  def to_s
    "#<Compiler name=#{name} width=#{@width} height=#{@height}>"
  end
  
  def initialize(settings)
    @urls = settings["urls"] || {}
    # @id = settings["id"] || raise("Time Machine must have unique ID")
    # @version = settings["version"] || raise("Time Machine must have version")
    # @versioned_id = "#{@id}-v#{@version}"
    # @label = settings["label"] || raise("Time Machine must have label")
    # STDERR.puts "Timemachine #{@id} (#{@label})"
    @store = settings['store'] || raise("No store")
    @store = File.expand_path(@store)
    STDERR.puts "Store is #{@store}"
    @stack_filter = settings['stack_filter']
    @video_filter = settings['video_filter']
    @tiles_dir = "#{store}/0200-tiles"
    @tilestack_dir = "#{store}/0300-tilestacks"
    @raw_tilestack_dir = @stack_filter ? "#{store}/0250-raw-tilestacks" : @tilestack_dir
    source_info = settings["source"] || raise("Time Machine must have source")
    initialize_source(source_info)

    # remove any old tmp json files which are passed to tilestacktool
    Filesystem.rm("#{@tiles_dir}/tiles-*.json")

    initialize_tilestack

    destination_info = settings["destination"]
    if ! destination_info
      destination_info = {"type" => "local"}
      STDERR.puts "No destination specified;  defaulting to #{JSON.pretty_generate(destination_info)}"
    end
    initialize_destination(destination_info)
    
    STDERR.puts "#{(@source.framenames.size*@source.width*@source.height/1e+9).round(1)} gigapixels total video content"
    STDERR.puts "#{@source.framenames.size} frames"
    STDERR.puts "#{(@source.width*@source.height/1e6).round(1)} megapixels per frame (#{@source.width}px x #{@source.height}px)"

    #initialize_original_images
    @videoset_compilers = settings["videosets"].map {|json| VideosetCompiler.new(self, json)}
    initialize_tiles

    # add time machine viewer templates to the ajax_includes file
    include_ajax_file("player_template.html")
    include_ajax_file("time_warp_composer.html")
    include_ajax_file("browser_not_supported_template.html")
    
  end

  def initialize_source(source_info)
    $sourcetypes[source_info["type"]] or raise "Source type must be one of #{$sourcetypes.keys.join(" ")}"
    @source = $sourcetypes[source_info["type"]].new(self, source_info)
    # Filesystem.write_file('autogenerated_framenames.txt', @source.framenames.join("\n"))
  end

  def initialize_tilestack
    Filesystem.mkdir_p @raw_tilestack_dir
    Filesystem.mkdir_p @tilestack_dir
    r = {'width' => @source.width, 'height' => @source.height,
         'tile_width' => @source.tilesize, 'tile_height' => @source.tilesize}
    Filesystem.write_file("#{@tilestack_dir}/r.json", JSON.pretty_generate(r))
  end

  def initialize_destination(destination_info)
    if destination_info.class == String
      @videosets_dir = destination_info
    else
      @videosets_parent_dir="#{store}/0400-videosets"
      @videosets_dir="#{@videosets_parent_dir}/#{@versioned_id}"
      if ! Filesystem.cached_exists? @videosets_parent_dir
        case destination_info["type"]
        when "local"
          Filesystem.mkdir_p @videosets_parent_dir
        when "symlink"
          target = destination_info["target"] or raise("Must specify 'target' for 'symlink' in 'destination'")
          Filesystem.cached_exists? target or raise("'target' path #{target} does not exist")
          File.symlink(target, @videosets_parent_dir)
        else
          raise "Destination type not recognized"
        end
      end
    end
    if not Filesystem.cached_exists? @videosets_dir
      videosets_tmp = "#{@videosets_dir}.#{temp_file_unique_fragment}"
      Filesystem.mkdir_p videosets_tmp
      Filesystem.cp_r ['css', 'images', 'js', 'player_template.html', 'time_warp_composer.html', 'save_snaplapse.html', 'load_snaplapse.html', 'browser_not_supported_template.html'].map{|path|"#{$explorer_source_dir}/#{path}"}, videosets_tmp
      Filesystem.cp "#{$explorer_source_dir}/integrated-viewer.html", "#{videosets_tmp}/view.html"
      Filesystem.mv videosets_tmp, @videosets_dir
    end
  end

  def initialize_tiles
    tileset = Tileset.new(@source.width, @source.height, @source.tilesize)
    @all_tiles = Set.new tileset.enumerate
    @max_level = tileset.max_level
    @base_tiles = tileset.enumerate_max_level
    @subsampled_tiles = tileset.enumerate_subsampled_levels
  end

  def all_tiles_rule
    Rule.touch("#{@tiles_dir}/COMPLETE", @source.tiles_rules)
  end

  def raw_tilestack_path(tile)
    "#{@raw_tilestack_dir}/#{tile.path}.ts2"
  end

  def tilestack_path(tile)
    "#{@tilestack_dir}/#{tile.path}.ts2"
  end

  def tilestack_rule(tile, dependencies)
    if Rule.has_target?(tile)
      return dependencies
    end
    children = tile.children.select {|t| @all_tiles.member? t}
    if children.size > 0
      subsampled_tilestack_rule(tile, children, dependencies)
    else
      base_tilestack_rule(tile, dependencies)
    end
  end

  def subsampled_tilestack_rule(target_idx, children, dependencies)
    target = tilestack_path(target_idx)
    children = children.flat_map {|child| tilestack_rule(child, dependencies)}

    cmd = tilestacktool_cmd
    cmd << "--create-parent-directories"
    frames = {'frames' => {'start' => 0, 'end' => @source.framenames.size - 1}, 
              'bounds' => target_idx.bounds(@source.tilesize, @max_level)}
    cmd += ['--path2stack', @source.tilesize, @source.tilesize, JSON.generate(frames), @tilestack_dir]
    cmd += ['--save', target]
    Rule.add(target, children, [cmd])
  end

  def base_tilestack_rule(target_idx, dependencies)
    targets = raw_base_tilestack_rule(target_idx, dependencies)
    if @stack_filter
      src = raw_tilestack_path(target_idx)
      dest = tilestack_path(target_idx)
      cmd = tilestacktool_cmd
      cmd << "--create-parent-directories"
      cmd += ['--load', src]
      cmd += @stack_filter
      cmd += ['--save', dest]
      targets = Rule.add(dest, targets, [cmd])
    end
    targets
  end

  def raw_base_tilestack_rule(target, dependencies)
    inputs = @source.framenames.map {|frame| "#{@tiles_dir}/#{frame}.data/tiles/#{target.path}.#{@source.tileformat}"}

    Filesystem.mkdir_p @tiles_dir
    json = {"tiles" => inputs}
    path = "#{@tiles_dir}/tiles-#{Process.pid}-#{Time.now.to_f}-#{rand(101010)}.json"
    Filesystem.write_file(path, JSON.fast_generate(json))

    target = raw_tilestack_path(target)
    cmd = tilestacktool_cmd # , "--delete-source-tiles"]
      cmd << "--create-parent-directories"
    cmd += ["--loadtiles-from-json"] + path.to_a
    cmd += ["--save", target]
    Rule.add(target, dependencies, [cmd])
  end

  def all_tilestacks_rule
    if $compute_tilestacks.none?
      STDERR.puts "   Skipping tilestack creation"
      []
    else
      STDERR.puts "   #{@base_tiles.size} base tiles per input frame (#{@source.tilesize}x#{@source.tilesize} px)"
      if @source.respond_to?(:tilestack_rules)
        targets = @source.tilestack_rules
        targets = Rule.touch("#{@raw_tilestack_dir}/SOURCE_COMPLETE", targets)
      else
        targets = all_tiles_rule
      end
      targets = tilestack_rule(Tile.new(0,0,0), targets)
      Rule.touch("#{@tilestack_dir}/COMPLETE", targets)
    end
  end
    
  # def tilestack_cleanup_rule
  #   #remove remaining .jpgs leftover and all sub directories
  #   #leave the top-most directory (*.data/tiles/r.info)
  #   #do not do anything if subsmaple is not 1 for the tiling
  #   cmd = @@global_parent.source.subsample == 1 ? ["find #{@tiles_dir} -name *.jpg | xargs rm -f", 
  #                                                  "find #{@tiles_dir} -type d | xargs rmdir --ignore-fail-on-non-empty"] : ["echo"]
  #   dependencies = all_tilestacks_rule.targets
  #   Rule.new(["tilestack-cleanup"], dependencies, 
  #            cmd, 
  #            {:local=>true})
  # end
  
  def videoset_rules
    # dependencies=tilestack_cleanup_rule.targets
    dependencies = all_tilestacks_rule
    Rule.touch("#{@videosets_dir}/COMPLETE", @videoset_compilers.flat_map {|vc| vc.rules(dependencies)})
  end

  # def capture_times_rule
  #   cmd = ["ruby #{@@global_parent.source.capture_time_parser}",
  #          "#{@@global_parent.source.capture_time_parser_inputs}",
  #          "#{@videosets_dir}/tm.json"]
  #   Rule.add("capture_times", videoset_rules, [cmd])
  # end

  def capture_times_rule
    source = @@global_parent.source.capture_times.nil? ? @@global_parent.source.capture_time_parser_inputs : @@jsonfile
    ruby_path = ($os == 'windows') ? File.dirname(__FILE__)+"/../ruby/windows/bin/ruby.exe" : "/usr/bin/ruby"
    Rule.add("capture_times", videoset_rules, [[ruby_path, "#{@@global_parent.source.capture_time_parser}", source, "#{@videosets_dir}/tm.json"]])
  end

  def compute_rules
    @@global_parent.source.capture_time_parser && Filesystem.cached_exists?(@@global_parent.source.capture_time_parser) ? capture_times_rule : videoset_rules
  end

  def info
    ret = {
      'datasets' => @videoset_compilers.map do |vc| 
        {
          'id' => vc.id,
          'name' => vc.label
        }
      end,
      'sizes' => @videoset_compilers.map(&:label)

    }
    @versioned_id and ret['base-id'] = @versioned_id
    @label and ret['name'] = @label
    ret
  end

  def write_json
    write_json_and_js("#{@videosets_dir}/tm", 'org.cmucreatelab.loadTimeMachine', info)
    include_ajax "./tm.json", info
    @videoset_compilers.each { |vc| vc.write_json }
  end

  def write_rules
    grouped_rules = Rule.all
    
    #STDERR.puts "Combined #{Rule.all.size-grouped_rules.size} rules to #{grouped_rules.size}"
    
    all_targets = grouped_rules.flat_map &:targets
    
    rules = []
    rules << "# generated by ct.rb"
    rules << "all: #{all_targets.join(" ")}"
    rules += grouped_rules.map { |rule| rule.to_make }
    Filesystem.write_file("#{store}/rules.txt", rules.join("\n\n"))
  end
end

class Maker
  @@ndone = 0
	
  def initialize(rules)
    @rules = rules
    @ready = []
    @targets={}
    @rules_waiting = {}
    @status = {}
    STDERR.write "Checking targets from #{rules.size} rules...  0%"
    rules.each_with_index do |rule, i| 
      if i*100/rules.size > (i-1)*100/rules.size
        STDERR.write("\b\b\b\b%3d%%" % (i*100/rules.size))
      end
      check_rule(rule)
    end
    STDERR.write("\b\b\b\bdone.\n")
  end

  def self.ndone
    @@ndone
  end
  
  def self.reset_ndone
    @@ndone = 0
  end

  def check_rule(rule)
    if @status[rule] == :done
      return
    elsif rule_targets_exist(rule)
      rule_completed(rule)
    elsif @status[rule] == :ready
      return
    elsif @status[rule] == :executing
      return
    else
      rule_ready = true
      rule.dependencies.each do |dep|
        if not target_exists?(dep)
          (@rules_waiting[dep] ||= Set.new) << rule
          rule_ready = false
        end
      end
      if rule_ready
        @status[rule] = :ready
        @ready << rule
      else
        @status[rule] = :waiting
      end
    end
  end

  def target_exists?(target)
    if @targets.member?(target)
      @targets[target]
    elsif File.basename(target) =~ /^dry-run-fake/
      @targets[target] = true
    else
      @targets[target] = Filesystem.cached_exists?(target)
    end
  end

  def rule_targets_exist(rule)
    rule.targets.each do |target|
      target_exists?(target) or return false
    end
    true
  end

  def rule_completed(rule)
    @status[rule] == :done and raise("assert")
    @status[rule] == :ready and raise("assert")
    @@ndone += 1
    @status[rule] = :done
    rule.targets.each do |target|
      if not @targets[target]
        @targets[target] = true
        if @rules_waiting.member?(target)
          @rules_waiting[target].each {|rule| check_rule(rule)}
        end
      end
    end
  end  

  def execute_rules(job_no, rules, response)
    begin
      counter = 1;

      $check_mem and CheckMem.logvm "Constructing job #{job_no}"

      if !$run_remotely || rules.all?(&:local)
        result = rules.flat_map(&:commands).all? do |command|
          STDERR.write "#{date} Job #{job_no} executing #{command.join(' ')}\n"
          if (command[0] == 'mv')
            File.rename(command[1], command[2])
          else
            ret = Kernel.system(*command) # This seems to randomly raise an exception in ruby 1.9
            unless ret
              STDERR.write "Command #{command.join(' ')} failed with ret=#{ret}, #{$?}\n"
            end
            ret
          end
        end
      else
        if $run_remotely_json
          json_file = "job_#{job_no}_#{Process.pid}.json"
          open(json_file, "w") do |json|
            json.puts "["
            commands = rules.flat_map(&:commands)
            commands.size.times do |i|
              i > 0 and json.puts ","
              json.write JSON.fast_generate commands[i]
            end
            json.puts "\n]"
          end
          command = "#{$run_remotely} --jobs @#{json_file}"
        else
          commands = rules.flat_map &:commands
          command = commands.join(" && ")
          command = "#{$run_remotely} '#{command}'"
        end
        STDERR.write "#{date} Job #{job_no} executing #{command}\n"
    
        # Retry up to 3 times if we fail
        while (!(result = system(command)) && counter < 4) do
          STDERR.write "#{date} Job #{job_no} failed, retrying, attempt #{counter}\n"
          counter += 1
        end
      end
    
      if !result
        STDERR.write "#{date} Job #{job_no} failed too many times; aborting\n"
        @aborting = true
        response.push([job_no, [], Thread.current])
      else
        STDERR.write "#{date} Job #{job_no} completed successfully\n"
        response.push([job_no, rules, Thread.current])
      end
    rescue Exception => e
      STDERR.write "#{date} Job #{job_no} failed to execute.\n"
      STDERR.write "#{e.message}\n"
      STDERR.write "#{e.backtrace.inspect}\n"
      @aborting = true
      response.push([job_no, [], Thread.current])
    end
  end

  def make(max_jobs, max_rules_per_job)
    begin_time = Time.now
    # build all rules
    # rule depends on dependencies:
    #    some dependencies already exist
    #    other dependencies are buildable by other rules
    # 1
    # loop through all rules
    #    if target already exists in filesystem, the rule is done
    #    if dependencies already exist in filesystem, the rule is ready to run
    #    for dependencies that don't already exist, create mapping from dependency to rule
    # 2
    # execute ready to run rules
    # when rule is complete, loop over rule targets and re-check any rules that depended on these targets to see
    #   if the rules can be moved to the "ready to run" set

    jobs_executing = 0
    rules_executing = 0
    response = Queue.new
    
    @aborting = false
    current_job_no = 0
    initial_ndone = @@ndone

    print_status(rules_executing, nil)

    while @@ndone < @rules.size
    	# Restart the process if we are stitching from source and we have not gotten dimensions from the first gigapan
      if @@global_parent.source.class.to_s == "StitchSource" && @@ndone > 0 && @@global_parent.source.width == 1 && @@global_parent.source.height == 1
        STDERR.write "Initial .gigapan file created. We now have enough info to get the dimensions.\n"
        STDERR.write "Clearing all old rules...\n"
        Rule.clear_all
        Maker.reset_ndone
        STDERR.write "Restarting process with new dimensions...\n"
        return
      end
      # Send jobs
      if !@aborting && !@ready.empty?
        jobs_to_fill = max_jobs - jobs_executing
        rules_per_job = (@ready.size.to_f / jobs_to_fill).ceil
        rules_per_job = [rules_per_job, max_rules_per_job].min
        rules_per_job > 0 or raise("assert")
        while !@ready.empty? && jobs_executing < max_jobs
          1.times do
            job_no = (current_job_no += 1)
            # Make sure to_run is inside this closure
            to_run = @ready.shift(rules_per_job)
            to_run.size > 0 or raise("assert")
            to_run.each do |rule| 
              @status[rule] == :ready or raise("assert")
              @status[rule]=:executing
            end
            STDERR.write "#{date} Job #{job_no} executing #{to_run.size} rules #{to_run[0]}...\n"
            if $dry_run
              response.push([job_no, to_run, nil])
            else
              Thread.new { execute_rules(job_no, to_run, response) }
            end
            jobs_executing += 1
            rules_executing += to_run.size
          end
        end
      end
      # Wait for job to finish
      if @aborting && jobs_executing == 0
        exit 1
      end
      if @ready.empty? && jobs_executing == 0
        STDERR.write "#{date}: Don't know how to build targets, aborting"
        exit 1
      end
      (job_no, rules, thread) = response.pop
      $dry_run || thread.join
      jobs_executing -= 1
      rules_executing -= rules.size
      rules.each {|rule| rule_completed(rule)}
      print_status(rules_executing, jobs_executing)
    end
    duration = Time.now.to_i - begin_time.to_i
    STDERR.write "#{date}: Completed #{@rules.size-initial_ndone} rules (#{current_job_no} jobs) in #{duration/86400}d #{duration%86400/3600}h #{duration%3600/60}m #{duration%60}s\n"
    if @aborting
      STDERR.write "Aborted due to error"
    end
  end

  def print_status(rules, jobs)
    status = []
    status << "#{(@@ndone*100.0/@rules.size).round(1)}% rules finished (#{@@ndone}/#{@rules.size})"
    rules && jobs && status << "#{rules} rules executing (in #{jobs} jobs)"
    status << "#{@ready.size} rules ready to execute"
    status << "#{@rules.size-@@ndone-@ready.size-rules} rules awaiting dependencies"
    STDERR.write "#{date} Rules #{status.join(". ")}\n"
  end

end

retry_attempts = 0
destination = nil

exe_suffix = ($os == 'windows') ? '.exe' : ''

tilestacktool_search_path = [File.expand_path("#{File.dirname(__FILE__)}/tilestacktool#{exe_suffix}"),
  			     File.expand_path("#{File.dirname(__FILE__)}/../tilestacktool/tilestacktool#{exe_suffix}")];



# If tilestacktool is not found in the project directory, assume it is in the user PATH
$tilestacktool = tilestacktool_search_path.find {|x| File.exists?(x)}

if $tilestacktool
  STDERR.puts "Found tilestacktool at #{$tilestacktool}"
else
  STDERR.puts "Could not find tilestacktool in path #{tilestacktool_search_path.join(':')}"
end

stitchpath = nil

def stitch_version_from_path(path)
  path.scan(/(GigaPan |gigapan-)(\d+)\.(\d+)\.(\d+)/) do |a,b,c,d|
    return sprintf('%05d.%05d.%05d', b.to_i, c.to_i, d.to_i)
  end
  return ''
end

# Check for stitch in the registry
if $os == 'windows'
  KEY_32_IN_64 = 'Software\Wow6432Node\Microsoft\Windows\CurrentVersion\Installer\Folders'
  KEY = 'Software\Microsoft\Windows\CurrentVersion\Installer\Folders'
  KEY_WOW64_64KEY = 0x0100

  reg = read_from_registry(Win32::Registry::HKEY_LOCAL_MACHINE,KEY_32_IN_64)
  reg = read_from_registry(Win32::Registry::HKEY_LOCAL_MACHINE,KEY) if reg.nil?

  if reg
    reg.each do |name, type, data|
      if stitch_version_from_path(name) > '00002' # Look for at least version 2.x
        stitchpath = name
        break
      end
    end
    reg.close
    if stitchpath.nil?
      STDERR.puts "Could not find an entry for stitch in the registry. Checking default installation path..."
    else
      stitchpath = File.join(stitchpath,"stitch.exe")
      STDERR.puts "Found stitch at: #{stitchpath}"
    end
  else
    STDERR.puts "Could not read registry."
  end
end

# If a path to stitch was not found in the registry or we are not on windows, check the default install path
if stitchpath.nil?
  if $os == 'osx'
    search = '/Applications/GigaPan */GigaPan Stitch */Contents/MacOS/GigaPan Stitch *'
  elsif $os == 'windows'
    search = 'C:/Program*/GigaPan*/*/stitch.exe'
  elsif $os == 'linux'
    search = File.expand_path(File.dirname(__FILE__)) + '/../gigapan-*.*.*-linux/stitch'
  end
  if search
    # If multiple versions, grab the path of the latest release
    found = Dir.glob(search).sort{|a,b| stitch_version_from_path(a) <=> stitch_version_from_path(b)}.reverse[0] 
    if not found
      STDERR.puts "Could not find stitch in default installation path: #{search}"
    elsif stitch_version_from_path(found) > '00002' # Look for at least version 2.x
      STDERR.puts "Found stitch at: #{found}"
      stitchpath = found
    else
      STDERR.puts "Found stitch at: #{found} but the version found does not support timelapses. Please update to at least version 2.x"
    end
  end
end

# If stitch is not found or the one found is too old, assume it is in the user PATH
$stitch = (stitchpath && File.exists?(stitchpath)) ? stitchpath : 'stitch'

explorer_source_search_path = [File.expand_path("#{File.dirname(__FILE__)}/time-machine-explorer"),
			       File.expand_path("#{File.dirname(__FILE__)}/../time-machine-explorer")]
			    
$explorer_source_dir = explorer_source_search_path.find {|x| File.exists? x}
if $explorer_source_dir
  STDERR.puts "Found explorer sources at #{$explorer_source_dir}"
else
  STDERR.puts "Could not find explorer sources in path #{explorer_source_search_path.join(':')}"
end

@@jsonfile = nil
destination = nil

njobs = 1
rules_per_job = 1

cmdline = "ct.rb #{ARGV.join(' ')}"

while !ARGV.empty?
  arg = ARGV.shift
  if arg == '-j'
    njobs = ARGV.shift.to_i
  elsif arg == '-r'
    rules_per_job  = ARGV.shift.to_i
  elsif arg == '--skip-tilestacks'
    $compute_tilestacks = Partial.none
  elsif arg == '--partial-tilestacks'
    $compute_tilestacks = Partial.new(ARGV.shift.to_i, ARGV.shift.to_i)
  elsif arg == '--skip-videos'
    $compute_videos = Partial.none
  elsif arg == '--partial-videos'
    $compute_videos = Partial.new(ARGV.shift.to_i, ARGV.shift.to_i)
  elsif arg == '-v'
    $verbose = true
  elsif arg == '--remote'
    $run_remotely = ARGV.shift
  elsif arg == '--remote-json'
    $run_remotely_json = true
  elsif arg == '--tilestacktool'
    $tilestacktool = File.expand_path ARGV.shift
  elsif File.extname(arg) == '.tmc'
    @@jsonfile = File.basename(arg) == 'definition.tmc' ? arg : "#{arg}/definition.tmc"
  elsif File.extname(arg) == '.timemachine'
    destination = File.expand_path(arg)
  elsif arg == '-n' || arg == '--dry-run'
    $dry_run = true
  elsif arg == '--selftest'
    exit self_test ? 0 : 1
  elsif arg == '--selftest-no-stitch'
    exit self_test(false) ? 0 : 1
  else
    STDERR.puts "Unknown arg #{arg}"
    usage
  end
end

$partial_vidoes = Partial.new(1, 10)

if !@@jsonfile 
  usage "Must give path to description.tmc"
end

if !destination
  usage "Must specify destination.timemachine"
end

# store is where all the intermediate files are created (0[123]00-xxx)
# store must be an absolute path
#
# Normally, the definition file is in a path foo.tmc/definition.tmc.  In this case,
# the store is foo.tmc
#
# If no description is 
#
# The store directory can be overridden in the .tmc file itself, using the "store" field

store = nil

if @@jsonfile
  if File.extname(File.dirname(@@jsonfile)) == ".tmc"
    store = File.dirname(@@jsonfile)
  end
end

STDERR.puts "Reading #{@@jsonfile}"
definition = JSON.parse(Filesystem.read_file(@@jsonfile))
definition['destination'] = destination
# .tmc "store" field overrides
store = definition['store'] || store

store or raise "No store specified.  Please place your definition.tmc inside a directory name.tmc and that will be your store"

store = File.expand_path store
definition['store'] = store   # For passing to the compiler.  Not ideal

Filesystem.cache_directory store
Filesystem.cache_directory destination

while ((Maker.ndone == 0 || Maker.ndone < Rule.all.size) && retry_attempts < 3)
  compiler = Compiler.new(definition)
  compiler.write_json
  Filesystem.write_file("#{@@global_parent.videosets_dir}/ajax_includes.js", 
                    ajax_includes_to_javascript)
  STDERR.puts "Wrote initial #{@@global_parent.videosets_dir}/ajax_includes.js"
  compiler.compute_rules # Creates rules, which will be accessible from Rule.all
  $check_mem and CheckMem.logvm "All rules created"
  # compiler.write_rules
  Maker.new(Rule.all).make(njobs, rules_per_job)
  retry_attempts += 1
end

# remove any old tmp json files which are passed to tilestacktool
Filesystem.rm("#{@@global_parent.tiles_dir}/tiles-*.json")

# Add tm.json to ajax_includes.js again to include the addition of capture times
include_ajax("./tm.json", JSON.parse(Filesystem.read_file("#{@@global_parent.videosets_dir}/tm.json")))

Filesystem.write_file("#{@@global_parent.videosets_dir}/ajax_includes.js", 
                      ajax_includes_to_javascript)
STDERR.puts "Wrote final #{@@global_parent.videosets_dir}/ajax_includes.js"

STDERR.puts "If you're authoring a mediawiki page at timemachine.gigapan.org, you can add this to #{compiler.urls['view'] || "your page"} to see the result: {{TimeWarpComposer}} {{TimelapseViewer|timelapse_id=#{compiler.versioned_id}|timelapse_dataset=1}}"
compiler.urls['track'] and STDERR.puts "and update tracking page #{compiler.urls['track']}"

STDERR.puts "View at file://#{destination}/view.html"

end_time = Time.new
STDERR.puts "Executiontook #{end_time-start_time} seconds"

if profile
  result = RubyProf.stop
  printer = RubyProf::GraphPrinter.new(result)
  STDERR.puts "Writing profile to #{profile}"
  open(profile, "w") do |out| 
    out.puts "Profile #{Time.new}"
    out.puts cmdline
    out.puts "Execution took #{end_time-start_time} seconds"
    out.puts
    printer.print(out, {})
  end
end
