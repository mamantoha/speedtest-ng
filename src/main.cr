require "./speedtest-cli"

module Speedtest
  @@test_in_progress = false

  def self.test_in_progress
    @@test_in_progress
  end

  def self.test_in_progress=(value)
    @@test_in_progress = value
  end
end

Process.on_terminate do
  if Speedtest.test_in_progress
    Speedtest.test_in_progress = false
  else
    puts
    puts "Cancelling..."
    exit
  end
end

Speedtest::CLI.run
