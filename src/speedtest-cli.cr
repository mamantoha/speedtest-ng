require "xml"
require "crest"

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

  def self.parse_servers(xml_data : String)
    xml = XML.parse(xml_data)
    first_server = xml.xpath_nodes("//servers/server").first?

    if first_server
      id = first_server["id"]?.to_s
      name = first_server["name"]?.to_s
      country = first_server["country"]?.to_s
      url = first_server["url"]?.to_s

      puts "First server found:"
      puts "ID: #{id}"
      puts "Name: #{name}"
      puts "Country: #{country}"
      puts "URL: #{url}"
    else
      puts "No servers found."
    end
  end
end

Speedtest::Cli.fetch_servers
