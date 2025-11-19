# frozen_string_literal: true

# This script creates a CNAME record set in AWS Route 53 and then polls
# the AWS API until the change propagation is complete (status is 'INSYNC').
#
# Prerequisites:
# 1. Install the AWS SDK for Ruby: `gem install aws-sdk-route53`
# 2. Configure your AWS credentials (e.g., via environment variables or ~/.aws/credentials).
# 3. This version automatically discovers the Hosted Zone ID.
#
# Usage:
# ruby create_cname_and_poll.rb <source_domain> <target_domain>
# Example: ruby create_cname_and_poll.rb "blog.example.com" "example-app.pikapod.net"

require 'aws-sdk-route53'
require 'timeout'

# ==============================================================================
# CONFIGURATION
# ==============================================================================

# Polling configuration
POLLING_INTERVAL_SECONDS = 5
MAX_WAIT_TIME_SECONDS = 300 # 5 minutes

# ==============================================================================
# ROUTE 53 API FUNCTIONS
# ==============================================================================

# Finds the most specific Hosted Zone ID that manages the given domain.
# This handles subdomains by looking for the parent zone (e.g., finding
# the example.com. zone for blog.example.com).
def find_hosted_zone_id(client, domain)
  # Ensure the domain being looked up is a FQDN (ends with a dot)
  fqdn = domain.end_with?('.') ? domain : "#{domain}."

  puts "Searching for Hosted Zone ID that manages the domain: #{fqdn}"

  # Initialize best match variables to find the most specific zone
  best_match_id = nil
  best_match_length = 0

  begin
    # list_hosted_zones returns all zones in the current account
    client.list_hosted_zones.hosted_zones.each do |zone|
      zone_name = zone.name

      # Check if the FQDN is managed by this zone.
      # 1. fqdn == zone_name (for the root domain itself, e.g., example.com. in example.com. zone)
      # 2. fqdn ends with .zone_name (for subdomains, e.g., blog.example.com. in example.com. zone)
      if fqdn == zone_name || fqdn.end_with?(".#{zone_name}")
        # Prioritize the longest match (most specific zone)
        if zone_name.length > best_match_length
          best_match_length = zone_name.length
          # The full ID is in the format /hostedzone/ID, so we extract the ID part
          best_match_id = zone.id.split('/').last
        end
      end
    end

    if best_match_id
      puts "Found Hosted Zone ID: #{best_match_id}"
      return best_match_id
    else
      puts "Error: Could not find a Hosted Zone ID managing the domain #{domain} in this AWS account."
      exit 1
    end
  rescue Aws::Errors::ServiceError => e
    puts "An AWS error occurred while listing hosted zones: #{e.message}"
    exit 1
  end
end

def create_cname_record(client, hosted_zone_id, source_domain, target_domain)
  # Ensure the source domain ends with a dot for FQDN (Fully Qualified Domain Name)
  cname_name = source_domain.end_with?('.') ? source_domain : "#{source_domain}."
  # Ensure the target domain (value) also ends with a dot
  cname_value = target_domain.end_with?('.') ? target_domain : "#{target_domain}."

  puts "Preparing to create CNAME record in Zone ID: #{hosted_zone_id}"
  puts "  Source: #{cname_name}"
  puts "  Target: #{cname_value}"

  change_batch = {
    hosted_zone_id: hosted_zone_id, # Use the dynamically discovered ID
    change_batch: {
      changes: [
        {
          action: 'CREATE',
          resource_record_set: {
            name: cname_name,
            type: 'CNAME',
            ttl: 300, # 5-minute Time-To-Live
            resource_records: [
              { value: cname_value }
            ]
          }
        }
      ],
      comment: "CNAME creation for #{source_domain} pointing to #{target_domain}"
    }
  }

  begin
    resp = client.change_resource_record_sets(change_batch)
    change_id = resp.change_info.id
    puts "Successfully initiated change request. Change ID: #{change_id}"
    return change_id
  rescue Aws::Route53::Errors::ResourceRecordSetAlreadyExists
    puts "Error: A resource record set with the name #{source_domain} already exists."
    exit 1
  rescue Aws::Route53::Errors::InvalidInput => e
    puts "Error: Invalid input provided."
    puts "AWS Message: #{e.message}"
    exit 1
  rescue Aws::Errors::ServiceError => e
    puts "An AWS error occurred during record creation: #{e.message}"
    exit 1
  end
end

def poll_for_completion(client, change_id)
  puts "\n--- Starting propagation check (max #{MAX_WAIT_TIME_SECONDS}s) ---"

  Timeout.timeout(MAX_WAIT_TIME_SECONDS) do
    loop do
      begin
        resp = client.get_change(id: change_id)
        status = resp.change_info.status
        comment = resp.change_info.comment
        time_stamp = resp.change_info.submitted_at

        puts "[#{Time.now.strftime('%H:%M:%S')}] Status: #{status}"

        if status == 'INSYNC'
          puts "\n*** Success! The DNS change has finished propagating (INSYNC). ***"
          puts "Change details: #{comment} (Submitted at: #{time_stamp})"
          break
        end

      rescue Aws::Errors::ServiceError => e
        puts "An AWS error occurred during polling: #{e.message}"
        # Exit the polling loop if a critical error occurs
        break
      end

      sleep POLLING_INTERVAL_SECONDS
    end
  end
rescue Timeout::Error
  puts "\n!!! Error: Timed out after #{MAX_WAIT_TIME_SECONDS} seconds while waiting for the change to sync. !!!"
  puts "Please check the status of Change ID #{change_id} in the AWS Route 53 console."
  exit 1
end

# ==============================================================================
# MAIN EXECUTION
# ==============================================================================

# Check for required command-line arguments
if ARGV.length != 2
  puts "Usage: ruby #{$PROGRAM_NAME} <source_domain> <target_domain>"
  puts "Example: ruby #{$PROGRAM_NAME} blog.example.com example-app.heroku.com"
  exit 1
end

source_domain = ARGV[0]
target_domain = ARGV[1]

# Initialize the Route 53 client
# We use 'us-east-1' as the region for Route 53 is generally irrelevant, 
# but a region must be specified for the SDK.
route53_client = Aws::Route53::Client.new(region: 'us-east-1')

# 1. Discover the Hosted Zone ID
hosted_zone_id = find_hosted_zone_id(route53_client, source_domain)

# 2. Create the CNAME record
change_id = create_cname_record(route53_client, hosted_zone_id, source_domain, target_domain)

# 3. Only poll if the change creation was successful
poll_for_completion(route53_client, change_id) unless change_id.nil?
