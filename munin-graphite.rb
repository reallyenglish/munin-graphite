#!/usr/local/bin/ruby
#
# munin-graphite.rb
# 
# A Munin-Node to Graphite bridge
#
# Author:: Adam Jacob (<adam@hjksolutions.com>)
# Copyright:: Copyright (c) 2008 HJK Solutions, LLC
# License:: GNU General Public License version 2 or later
# 
# This program and entire repository is free software; you can
# redistribute it and/or modify it under the terms of the GNU 
# General Public License as published by the Free Software 
# Foundation; either version 2 of the License, or any later version.
# 
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU General Public License for more details.
# 
# You should have received a copy of the GNU General Public License
# along with this program; if not, write to the Free Software
# Foundation, Inc., 51 Franklin St, Fifth Floor, Boston, MA  02110-1301  USA
# 

# TODO
# - use daemons
# - create generic log interface

require 'rubygems'
require 'munin-ruby'
require 'optparse'
require 'syslog'
require 'daemons'

class Carbon
  def initialize(host='localhost', port=2003)
    @carbon = TCPSocket.new(host, port)
  end
  
  def send(msg)
    @carbon.puts(msg)
  end
  
  def close
    @carbon.close
  end
end

def change_privilege(user, group=user)
  uid, gid = Process.euid, Process.egid
  target_uid = Etc.getpwnam(user).uid
  target_gid = Etc.getgrnam(group).gid

  if uid != target_uid || gid != target_gid
    Process.initgroups(user, target_gid)
    Process::GID.change_privilege(target_gid)
    Process::UID.change_privilege(target_uid)
  end
rescue Errno::EPERM => e
  raise "Couldn't change user and group to #{user}:#{group}: #{e}"
end

option_of = {
  :carbon_host  => "localhost",
  :carbon_port  => 2003,
  :munin_host  => "localhost",
  :munin_port  => 4949,
  :interval     => 60,
  :metric_base  => "servers",
  :user     => nil,
  :piddir     => nil
}

OptionParser.new do |opts|
  opts.banner = "Usage: example.rb [options]"
  opts.on( '-h', '--help', 'Display this screen' ) do
  end
  opts.on( '--munin-host VALUE' ) do |munin_host|
    option_of[:munin_host] = munin_host
  end
  opts.on( '--munin-port VALUE' ) do |munin_port|
    option_of[:munin_port] = munin_port.to_i
  end
  opts.on( '--carbon-host VALUE' ) do |carbon_host|
    option_of[:carbon_host] = carbon_host
  end
  opts.on( '--carbon-port VALUE' ) do |carbon_port|
    option_of[:carbon_port] = carbon_port.to_i
  end
  opts.on( '--interval VALUE' ) do |interval|
    option_of[:interval] = interval.to_i
  end
  opts.on( '--metric-base VALUE' ) do |metric_base|
    option_of[:metric_base] = metric_base
  end
  opts.on( '--debug' ) do |debug|
    option_of[:debug] = debug
  end
  opts.on( '--user VALUE' ) do |user|
    option_of[:user] = user
  end
  opts.on( '--piddir VALUE' ) do |pidfile|
    option_of[:piddir] = pidfile
  end
end.parse!

if option_of[:user]
  if Process.euid == 0
    change_privilege(option_of[:user])
  else
    puts "cannot drop priv, please run as root"
    exit 1
  end
end

myname = File.basename(__FILE__).split(".").first
Daemons.daemonize(
  :ontop => option_of[:debug],
  :dir_mode => option_of[:piddir] ? :normal : :script,
  :dir => option_of[:piddir] ? option_of[:piddir] : nil,
  :app_name => myname
)

syslog_option = option_of[:debug] ? Syslog::LOG_PERROR : Syslog::LOG_PID
syslog_facility = Syslog::LOG_USER
Syslog.open(myname, syslog_option, syslog_facility)

while true
  all_metrics = []

  begin
    node = Munin::Node.new(option_of[:munin_host], option_of[:munin_port])
    fqdn = node.nodes.first
    node.list.sort.each do |service|
      config = node.config("#{service}")
      metric_of = node.fetch("#{service}")["#{service}"]
      metric_of.keys.sort.each do |field|
        metric = [ option_of[:metric_base], fqdn.split(".").reverse, service, field ].join(".")
        value = metric_of["#{field}"]
        now = Time.now.to_i
        all_metrics << "#{metric} #{value} #{now}"
      end
    end
  rescue Munin::ConnectionError => ex
    Syslog.err("%s" % ex.message)
    Syslog.err("%s" % ex.backtrace.inspect)
    Syslog.err("retrying in %d sec" % option_of[:interval])
    sleep option_of[:interval]
    retry
  rescue Exception => ex
    Syslog.err("%s" % ex.message)
    Syslog.err("%s" % ex.backtrace.inspect)
    raise
  end

  carbon = Carbon.new(option_of[:carbon_host], option_of[:carbon_port])
  all_metrics.each do |m|
    Syslog.info "Sending #{m}" if option_of[:debug]
    # XXX rescue me
    carbon.send(m)
  end

  sleep option_of[:interval]
end

