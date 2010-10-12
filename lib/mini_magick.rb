require 'tempfile'
require 'subexec'
require 'open-uri'

module MiniMagick
  class << self
    attr_accessor :processor
    attr_accessor :timeout
  end
  
  MOGRIFY_COMMANDS = %w{adaptive-blur adaptive-resize adaptive-sharpen adjoin affine alpha annotate antialias append authenticate auto-gamma auto-level auto-orient background bench iterations bias black-threshold blue-primary point blue-shift factor blur border bordercolor brightness-contrast caption string cdl filename channel type charcoal radius chop clip clamp clip-mask filename clip-path id clone index clut contrast-stretch coalesce colorize color-matrix colors colorspace type combine comment string compose operator composite compress type contrast convolve coefficients crop cycle amount decipher filename debug events define format:option deconstruct delay delete index density depth despeckle direction type display server dispose method distort type coefficients dither method draw string edge radius emboss radius encipher filename encoding type endian type enhance equalize evaluate operator evaluate-sequence operator extent extract family name fft fill filter type flatten flip floodfill flop font name format string frame function name fuzz distance fx expression gamma gaussian-blur geometry gravity type green-primary point help identify ifft implode amount insert index intent type interlace type interline-spacing interpolate method interword-spacing kerning label string lat layers method level limit type linear-stretch liquid-rescale log format loop iterations mask filename mattecolor median radius modulate monitor monochrome morph morphology method kernel motion-blur negate noise radius normalize opaque ordered-dither NxN orient type page paint radius ping pointsize polaroid angle posterize levels precision preview type print string process image-filter profile filename quality quantizespace quiet radial-blur angle raise random-threshold low,high red-primary point regard-warnings region remap filename render repage resample resize respect-parentheses roll rotate degrees sample sampling-factor scale scene seed segments selective-blur separate sepia-tone threshold set attribute shade degrees shadow sharpen shave shear sigmoidal-contrast size sketch solarize threshold splice spread radius strip stroke strokewidth stretch type style type swap indexes swirl degrees texture filename threshold thumbnail tile filename tile-offset tint transform transparent transparent-color transpose transverse treedepth trim type type undercolor unique-colors units type unsharp verbose version view vignette virtual-pixel method wave weight type white-point point white-threshold write filename}

  class Error < RuntimeError; end
  class Invalid < StandardError; end

  class Image
    attr :path

    # Class Methods
    # -------------
    class << self
      # This is the primary loading method used by all of the other class methods.
      # Pass in a string-like object that holds the binary data for a valid image
      #
      # Use this to pass in a stream object. Must respond to Object#read #=> String or be a String-like object already
      #
      # Probably easier to use the open method if you want to read something in.
      #
      # @param stream [#read, String-like] Some kind of stream object that needs to be read or is already a String
      # @param ext [String] A manual extension to use for reading the file. Not required, but if you are having issues, give this a try.
      # @return [Image]
      def read(stream, ext = nil)
        begin
          if stream.respond_to?("read")
            stream = stream.read
          end

          tempfile = Tempfile.new(['mini_magick', ext.to_s])
          tempfile.binmode
          tempfile.write(stream)
        ensure
          tempfile.close if tempfile
        end

        image = self.new(tempfile.path, tempfile)
        if !image.valid?
          raise MiniMagick::Invalid
        end
        image
      end

      # @deprecated Please use Image.read instead!
      def from_blob(blob, ext = nil)
        warn "Warning: MiniMagick::Image.from_blob method is deprecated. Instead, please use Image.read"
        read(blob, ext)
      end

      # Opens a specific image file either on the local file system or at a URI.
      #
      # Use this if you don't want to overwrite the image file.
      #
      # Extension is either guessed from the path or you can specify it as a second parameter.
      #
      # If you pass in what looks like a URL, we will see if Kernel#open exists. If it doesn't
      # then we require 'open-uri'. That way, if you have a work-alike library, we won't demolish it.
      # Open-uri never gets required unless you pass in something with "://" in it.
      #
      # @param file_or_url [String] Either a local file path or a URL that open-uri can read
      # @param ext [String] Specify the extension you want to read it as
      # @return [Image] The loaded image
      def open(file_or_url, ext = File.extname(file_or_url))
        if file_or_url.include?("://")
          if !Kernel.respond_to?("open")
            require 'open-uri'
          end
          self.read(Kernel::open(file_or_url), ext)
        else
          File.open(file_or_url, "rb") do |f|
            self.read(f, ext)
          end
        end
      end

      # @deprecated Please use MiniMagick::Image.open(file_or_url) now
      def from_file(file, ext = nil)
        warn "Warning: MiniMagick::Image.from_file is now deprecated. Please use Image.open"
        open(file, ext)
      end
      
    end

    # Instance Methods
    # ----------------
    
    
    # Create a new MiniMagick::Image object
    #
    # _DANGER_: The file location passed in here is the *working copy*. That is, it gets *modified*. 
    # you can either copy it yourself or use the MiniMagick::Image.open(path) method which creates a
    # temporary file for you and protects your original!
    #
    # @param input_path [String] The location of an image file
    # @todo Allow this to accept a block that can pass off to Image#combine_options
    def initialize(input_path, tempfile = nil)
      @path = input_path
      @tempfile = tempfile # ensures that the tempfile will stick around until this image is garbage collected.
    end
    
    # Checks to make sure that MiniMagick can read the file and understand it.
    #
    # This uses the 'identify' command line utility to check the file. If you are having
    # issues with this, then please work directly with the 'identify' command and see if you
    # can figure out what the issue is.
    #
    # @return [Boolean]
    def valid?
      run_command("identify", @path)
      true
    rescue MiniMagick::Invalid
      false
    end

    # A rather low-level way to interact with the "identify" command. No nice API here, just
    # the crazy stuff you find in ImageMagick. See the examples listed!
    #
    # @example
    #    image["format"]      #=> "TIFF"
    #    image["height"]      #=> 41 (pixels)
    #    image["width"]       #=> 50 (pixels)
    #    image["dimensions"]  #=> [50, 41]
    #    image["size"]        #=> 2050 (bits)
    #    image["original_at"] #=> 2005-02-23 23:17:24 +0000 (Read from Exif data)
    #    image["EXIF:ExifVersion"] #=> "0220" (Can read anything from Exif)
    #
    # @param format [String] A format for the "identify" command
    # @see For reference see http://www.imagemagick.org/script/command-line-options.php#format
    # @return [String, Numeric, Array, Time, Object] Depends on the method called! Defaults to String for unknown commands
    def [](value)
      # Why do I go to the trouble of putting in newlines? Because otherwise animated gifs screw everything up
      case value.to_s
      when "format"
        run_command("identify", "-format", format_option("%m"), @path).split("\n")[0]
      when "height"
        run_command("identify", "-format", format_option("%h"), @path).split("\n")[0].to_i
      when "width"
        run_command("identify", "-format", format_option("%w"), @path).split("\n")[0].to_i
      when "dimensions"
        run_command("identify", "-format", format_option("%w %h"), @path).split("\n")[0].split.map{|v|v.to_i}
      when "size"
        File.size(@path) # Do this because calling identify -format "%b" on an animated gif fails!
      when "original_at"
        # Get the EXIF original capture as a Time object
        Time.local(*self["EXIF:DateTimeOriginal"].split(/:|\s+/)) rescue nil
      when /^EXIF\:/i
        result = run_command('identify', '-format', "\"%[#{value}]\"", @path).chop
        if result.include?(",")
          read_character_data(result)
        else
          result
        end
      else
        run_command('identify', '-format', "\"#{value}\"", @path).split("\n")[0]
      end
    end

    # Sends raw commands to imagemagick's `mogrify` command. The image path is automatically appended to the command.
    #
    # Remember, we are always acting on this instance of the Image when messing with this.
    #
    # @return [String] Whatever the result from the command line is. May not be terribly useful.
    def <<(*args)
      run_command("mogrify", *args << @path)
    end

    # This is used to change the format of the image. That is, from "tiff to jpg" or something like that.
    # Once you run it, the instance is pointing to a new file with a new extension!
    #
    # *DANGER*: This renames the file that the instance is pointing to. So, if you manually opened the
    # file with Image.new(file_path)... then that file is DELETED! If you used Image.open(file) then
    # you are ok. The original file will still be there. But, any changes to it might not be...
    #
    # Formatting an animation into a non-animated type will result in ImageMagick creating multiple
    # pages (starting with 0).  You can choose which page you want to manipulate.  We default to the
    # first page.
    #
    # @param format [String] The target format... like 'jpg', 'gif', 'tiff', etc.
    # @param page [Integer] If this is an animated gif, say which 'page' you want with an integer. Leave as default if you don't care.
    # @return [nil]
    def format(format, page = 0)
      run_command("mogrify", "-format", format, @path)

      old_path = @path.dup
      @path.sub!(/(\.\w*)?$/, ".#{format}")
      File.delete(old_path) if old_path != @path

      unless File.exists?(@path)
        begin
          FileUtils.copy_file(@path.sub(".#{format}", "-#{page}.#{format}"), @path)
        rescue => ex
          raise MiniMagickError, "Unable to format to #{format}; #{ex}" unless File.exist?(@path)
        end
      end
    ensure
      Dir[@path.sub(/(\.\w+)?$/, "-[0-9]*.#{format}")].each do |fname|
        File.unlink(fname)
      end
    end
    
    # Collapse images with sequences to the first frame (ie. animated gifs) and
    # preserve quality
    def collapse!
      run_command("mogrify", "-quality", "100", "#{path}[0]")
    end

    # Writes the temporary image that we are using for processing to the output path
    def write(output_path)
      FileUtils.copy_file @path, output_path
      run_command "identify", output_path # Verify that we have a good image
    end

    # Gives you raw image data back
    # @return [String] binary string
    def to_blob
      f = File.new @path
      f.binmode
      f.read
    ensure
      f.close if f
    end

    # If an unknown method is called then it is sent through the morgrify program
    # Look here to find all the commands (http://www.imagemagick.org/script/mogrify.php)
    def method_missing(symbol, *args)
      combine_options do |c|
        c.method_missing(symbol, *args)
      end
    end

    # You can use multiple commands together using this method. Very easy to use!
    #
    # @example 
    #   image.combine_options do |c|
    #     c.draw "image Over 0,0 10,10 '#{MINUS_IMAGE_PATH}'"
    #     c.thumbnail "300x500>"
    #     c.background background
    #   end
    #
    # @yieldparam command [CommandBuilder] 
    def combine_options(&block)
      c = CommandBuilder.new('mogrify')
      block.call(c)
      c << @path
      run(c)
    end

    # Check to see if we are running on win32 -- we need to escape things differently
    def windows?
      !(RUBY_PLATFORM =~ /win32/).nil?
    end
    
    def composite(other_image, output_extension = 'jpg', &block)
      begin
        second_tempfile = Tempfile.new(output_extension)
        second_tempfile.binmode
      ensure
        second_tempfile.close
      end
      
      command = CommandBuilder.new("composite")
      block.call(command) if block
      command.push(other_image.path)
      command.push(self.path)
      command.push(second_tempfile.path)
      
      run(command)
      return Image.new(second_tempfile.path, second_tempfile)
    end

    # Outputs a carriage-return delimited format string for Unix and Windows
    def format_option(format)
      windows? ? "\"#{format}\\n\"" : "\"#{format}\\\\n\""
    end

    def run_command(command, *args)
      run(CommandBuilder.new(command, *args))
    end
    
    def run(command_builder)
      command = command_builder.command

      sub = Subexec.run(command, :timeout => MiniMagick.timeout)

      if sub.exitstatus != 0
        # Clean up after ourselves in case of an error
        destroy!
        
        # Raise the appropriate error
        if sub.output =~ /no decode delegate/i || sub.output =~ /did not return an image/i
          raise Invalid, sub.output
        else
          # TODO: should we do something different if the command times out ...?
          # its definitely better for logging.. otherwise we dont really know
          raise Error, "Command (#{command.inspect.gsub("\\", "")}) failed: #{{:status_code => sub.exitstatus, :output => sub.output}.inspect}"
        end
      else
        sub.output
      end
    end
    
    def destroy!
      return if @tempfile.nil?
      File.unlink(@tempfile.path)
      @tempfile = nil
    end
    
    private
      # Sometimes we get back a list of character values
      def read_character_data(list_of_characters)
        chars = list_of_characters.gsub(" ", "").split(",")
        result = ""
        chars.each do |val|
          result << ("%c" % val.to_i)
        end
        result
      end
  end

  class CommandBuilder
    attr :args
    attr :command

    def initialize(command, *options)
      @command = command
      @args = []
      options.each { |arg| push(arg) }
    end
    
    def command
      "#{MiniMagick.processor} #{@command} #{@args.join(' ')}".strip
    end
    
    def method_missing(symbol, *options)
      guessed_command_name = symbol.to_s.gsub('_','-')
      if guessed_command_name == "format"
        raise Error, "You must call 'format' on the image object directly!"
      elsif MOGRIFY_COMMANDS.include?(guessed_command_name)
        add(guessed_command_name, *options)
      else
        super(symbol, *args)
      end
    end
    
    def add(command, *options)
      push "-#{command}"
      if options.any?
        push "\"#{options.join(" ")}\""
      end
    end
    
    def push(arg)
      @args << arg.strip
    end
    alias :<< :push

    # @deprecated Please don't use the + method its has been deprecated
    def +(value)
      warn "Warning: The MiniMagick::ComandBuilder#+ command has been deprecated. Please use c << '+#{value}' instead"
      push "+#{value}"
    end
  end
end
