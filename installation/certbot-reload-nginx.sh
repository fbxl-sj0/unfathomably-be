#!/bin/sh

#
# Unfathomably ATProto PDS
# -----------------------
#
# File: certbot-reload-nginx.sh
#
# Purpose:
#
#     Load renewed certificate files into the public reverse proxy.
#
# Responsibilities:
#
#     - validate the complete Nginx configuration
#     - reload Nginx only after successful validation
#
# This file intentionally does NOT request or renew certificates.
#

set -eu

nginx -t
systemctl reload nginx

# end of certbot-reload-nginx.sh
