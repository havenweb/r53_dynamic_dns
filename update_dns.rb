#!/usr/bin/env ruby
require 'aws-sdk-route53'

def update_ip(domain, new_ip_addr)
  client = Aws::Route53::Client.new
  hosted_zones = client.list_hosted_zones.hosted_zones
  domain_zones = hosted_zones.select{|zone| zone.name.start_with? domain}
  if domain_zones.size != 1
    raise "Did not find exactly one hosted zone for domain #{domain}.  Found: #{domain_zones}"
  end
  zone_id = domain_zones.first.id

  record_sets = client.list_resource_record_sets(hosted_zone_id: zone_id).resource_record_sets  
  a_records = record_sets.select{|rec| rec.type == "A"}
  if (a_records.size !=1)
    raise "Did not find exactly one A record, found: #{a_records.to_s}"
  end
  old_ip_addr = a_records.first.resource_records.first.value
  if old_ip_addr == new_ip_addr
    puts "Current DNS IP matches current IP: #{old_ip_addr}"
    exit
  end

  change_request = {
    change_batch: {
      changes: [
        {
          action: "UPSERT", 
          resource_record_set: {
            name: domain, 
            resource_records: [
              {
                value: new_ip_addr, 
              }, 
            ], 
            ttl: 300, 
            type: "A", 
          }, 
        }, 
      ], 
      comment: "", 
    }, 
    hosted_zone_id: zone_id, 
  }

  puts client.change_resource_record_sets(change_request).to_h
end


domain = ARGV[0]
raise "Please specify the domain as an argument" if domain.nil?
puts "Checking if update required for #{domain}"
ip_file = "#{Dir.home}/.dyndns_ip_address"
new_ip = `curl -s 'https://api.ipify.org'`

if (File.exist? ip_file)
  old_ip = File.read(ip_file)
  if old_ip == new_ip
    puts "No change, IP: #{new_ip}"
    exit(0)
  end
end

puts "IP Changed to: #{new_ip}"
update_ip(domain, new_ip)

File.open(ip_file, "w") do |file|
  file.write(new_ip)
end
