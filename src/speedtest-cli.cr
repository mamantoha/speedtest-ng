require "xml"
require "crest"

class SpeedtestConfig
  getter upload_maxchunkcount : Int32
  getter upload_threads : Int32
  getter download_threadsperurl : Int32

  def initialize(xml_content : String)
    xml = XML.parse(xml_content)
    @upload_maxchunkcount = xml.xpath_nodes("//upload/@maxchunkcount").first.try(&.content).try(&.to_i) || 10
    @upload_threads = xml.xpath_nodes("//upload/@threads").first.try(&.content).try(&.to_i) || 2
    @download_threadsperurl = xml.xpath_nodes("//upload/@threadsperurl").first.try(&.content).try(&.to_i) || 4
  end
end

def fetch_speedtest_config
  url = "https://www.speedtest.net/speedtest-config.php"

  begin
    response = HTTP::Client.get(url)
    if response.success?
      return SpeedtestConfig.new(response.body)
    else
      puts "Failed to fetch config, using defaults."
      return SpeedtestConfig.new("")
    end
  rescue ex
    puts "Error fetching speedtest config: #{ex.message}"
    return SpeedtestConfig.new("")
  end
end

module Speedtest::Cli
  VERSION = "0.1.0"

  def self.fetch_servers
    url = "https://www.speedtest.net/speedtest-servers.php"
    response = Crest.get(url)

    if response.success?
      parse_servers(response.body)
    else
      raise "Failed to fetch Speedtest servers: #{response.status_code}"
    end
  end

  # Parses XML and gets the first server
  def self.parse_servers(xml_data : String)
    xml = XML.parse(xml_data)
    first_server = xml.xpath_nodes("//servers/server").first?

    if first_server
      {
        id: first_server["id"]?.to_s,
        name: first_server["name"]?.to_s,
        country: first_server["country"]?.to_s,
        url: first_server["url"]?.to_s
      }
    else
      raise "No servers found."
    end
  end

  def self.test_download_speed(server_url : String, config : SpeedtestConfig)
    base_url = server_url.sub(/\/upload\.php$/, "")
    test_sizes = [350, 500, 750, 1000, 1500, 2000, 2500, 3000, 3500, 4000]
    download_count = config.download_threadsperurl  # Use actual thread count

    puts "Testing download speed:"

    total_bytes = Atomic(Int64).new(0)
    start_time = Time.monotonic
    channel = Channel(Nil).new(test_sizes.size * download_count)

    test_sizes.each do |size|
      download_count.times do
        spawn do
          url = "#{base_url}/random#{size}x#{size}.jpg"
          begin
            response = HTTP::Client.get(url)
            if response.success?
              total_bytes.add(response.body.bytesize)
              print "."
              STDOUT.flush
            end
          rescue ex
            print "E"
          ensure
            channel.send(nil)
          end
        end
      end
    end

    (test_sizes.size * download_count).times { channel.receive }

    puts "\n"
    end_time = Time.monotonic
    time_taken = (end_time - start_time).total_seconds
    speed_mbps = (total_bytes.get * 8) / (time_taken * 1_000_000.0)

    puts "Download: #{speed_mbps.round(2)} Mbit/s"
  end

  def self.test_upload_speed(server_url : String, config : SpeedtestConfig)
    base_url = server_url.sub(/\/upload\.php$/, "")
    upload_sizes = [32768, 65536, 131072, 262144, 524288, 1048576, 7340032]
    upload_max = config.upload_maxchunkcount
    upload_count = (upload_max / upload_sizes.size).ceil.to_i
    upload_url = "#{base_url}/upload.php"

    puts "Testing upload speed:"

    total_bytes = Atomic(Int64).new(0)
    start_time = Time.monotonic
    channel = Channel(Nil).new(upload_sizes.size * upload_count)

    upload_sizes.each do |size|
      upload_count.times do
        spawn do
          begin
            random_data = Random::Secure.random_bytes(size)
            response = HTTP::Client.post(upload_url, body: random_data)
            if response.success?
              total_bytes.add(size)
              print "."
              STDOUT.flush
            end
          rescue ex
            print "E"
          ensure
            channel.send(nil)
          end
        end
      end
    end

    (upload_sizes.size * upload_count).times { channel.receive }

    puts "\n"
    end_time = Time.monotonic
    time_taken = (end_time - start_time).total_seconds
    speed_mbps = (total_bytes.get * 8) / (time_taken * 1_000_000.0)

    puts "Upload: #{speed_mbps.round(2)} Mbit/s"
  end

  def self.run
    puts "Fetching Speedtest Configuration..."
    config = fetch_speedtest_config

    server = fetch_servers
    puts "Using Server: #{server[:name]}, #{server[:country]}"

    test_download_speed(server[:url], config)
    test_upload_speed(server[:url], config)
  end
end

Speedtest::Cli.run
