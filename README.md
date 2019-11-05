# Route 53 Dynamic DNS

This is a simple script that checks the server's public IP address, then updates a DNS record in AWS Route 53 to point to that server.  Stick it in the crontab of a home server and you can host a website (or other content) even if you don't have a static IP address from your internet service provider

Note: Do not host a web server from your home if it is against the terms of service for your internet service provider

## Usage

```
ruby update_dns.rb example.com
```
Replace `example.com` with your domain name.

The script will also create a file: `.dyndns_ip_address` in your home directory.  This allows it to save the previously recorded public IP address and only query Route 53 if an update is needed.
