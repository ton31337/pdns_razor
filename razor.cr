require "redis"
require "logger"
require "big"

class Razor

  def initialize(unixsocket = nil, host = "127.0.0.1", port = 6379, types = %w(SOA NS AAAA A), banner = "Razor DNS backend", debug = false)
    @types = types
    @banner = banner
    @redis = Redis.new(host: host, port: port, unixsocket: unixsocket)
    @debug = debug
    @log = Logger.new(STDERR)
    @log.level = Logger::INFO
  end

  def run!
    banner
    mainLoop
  end

  def mainLoop
    loop do
      qname, qtype, edns = parse_query STDIN.read_line
      name = qname.downcase
      ttl = ttl(name)

      case qtype
      when "SOA"
        options = {
          :name => name,
          :type => qtype,
          :ttl => ttl,
          :content => soa(name)
        }
        answer options
      when "ANY"
        @types.each do |type|
          data_from_redis(type, name, edns).each do |response|
            options = {
              :name => name,
              :type => type,
              :ttl => ttl,
              :content => response
            }
            answer options
          end
        end
      end
      finish
    end
  end

  private def ipv4_int(ip)
    ip_int = 0.to_big_i
    ip.split(".").each_with_index do |oct, i|
      ip_int |= oct.to_big_i << (32 - 8 * (i + 1))
    end
    ip_int
  end

  private def ipv6_decompress(ip)
    ip_arr = [] of String
    splitted = ip.split("")
    compressed = 8 - ip.split(":").size
    splitted.size.times do |i|
      ip_arr << splitted[i]
      if splitted[i] == ":" && splitted[i+1] == ":"
        compressed.times do |_|
          ip_arr << "0" << ":"
        end
        ip_arr << "0"
      end
    end
    ip_arr.join
  end

  private def ipv6_int(ip)
    ip_int = 0.to_big_i
    ipv6_decompress(ip).split(":").each_with_index do |word, i|
      ip_int |= word.rjust(4, '0').to_big_i(16) << (128 - 16 * (i + 1))
    end
    ip_int
  end

  private def ip_hashed(ip, count)
    if ip.includes?(":")
      (ipv6_int(ip) >> (128 - 48)) % count
    else
      (ipv4_int(ip) & 0xffffff00) % count
    end
  end

  private def ttl(name)
    @redis.hmget(name, "TTL").first || 60
  end

  private def soa(name)
    @redis.hmget(name, "SOA").first
  end

  private def answer_type(name)
    @redis.hmget(name, "ANSWER").first || "random"
  end

  private def servers_count(name)
    @redis.smembers(name).size
  end

  private def dns_groups(name)
    @redis.smembers("#{name}:GROUPS") || [] of String
  end

  private def edns_ip(edns)
    edns.split("/")[0]
  end

  private def ch_content(name, edns)
    hash = ip_hashed(edns_ip(edns), servers_count(name))
    @redis.smembers(name)[hash]
  end

  private def gch_content(qtype, groups, edns)
    hash = ip_hashed(edns_ip(edns), groups.size)
    @redis.srandmember("#{groups[hash]}:#{qtype}")
  end

  private def data_from_redis(qtype, name, edns)
    case qtype
    when "SOA"
      [soa(name)]
    when "NS"
      @redis.smembers("#{name}:#{qtype}")
    else
      case answer_type(name)
      when "random"
        [@redis.srandmember("#{name}:#{qtype}")]
      when "consistent_hash"
        [ch_content("#{name}:#{qtype}", edns)]
      when "group_consistent_hash"
        [gch_content(qtype, dns_groups(name), edns)]
      else
        [] of String
      end
    end
  end

  private def answer(options = {} of Symbol => String|Int32)
    options = {
      :scopebits => 24,
      :auth => 1,
      :id => -1,
      :class => "IN"
    }.merge options
    respond "DATA",
            options[:scopebits],
            options[:auth],
            options[:name],
            options[:class],
            options[:type],
            options[:ttl],
            options[:id],
            options[:content] if options[:content]
  end

  private def respond(*args)
    STDOUT.print(args.join("\t") + "\n")
    @log.info(args.join("\t") + "\n") if @debug
  end

  private def finish
    respond "END"
  end

  private def banner
    STDIN.read_line
    respond "OK", @banner
  end

  private def parse_query(input)
    _, name, _, qtype, _, _, _, edns = input.chomp.split("\t")
    @log.info(input.chomp) if @debug
    return name, qtype, edns
  end
end

Razor.new(unixsocket: "/var/run/redis/6379/redis.sock").run!
