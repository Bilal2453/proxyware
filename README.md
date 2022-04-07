# proxyware
A simple middleware router proxy over TCP written in Lua, using the Luvit platform.
This project is for personal use, I use it over my local home server.

Note that there is no TLS support (yet?) since I don't need that for a private local-only network... and properly implementing it will be hell.

## Installation

Not sure why would you want to actually use this instead of nginx, but you do you.

`git clone https://github.com/Bilal2453/proxyware.git`

or if the Git install PR was merged to Lit:

`lit install https://github.com/Bilal2453/proxyware.git`

## Configuring it

Open `proxyware.lua` and edit the constants at the top, available options are:

|  |   |   |
| - | - | - |
| PORT | number | The port on which this server will start listening |
| DOMAIN | string | On which interface/domain the server will listen on |
| LOCAL_HOST | string | The IP of the server on which the instances are hosted |
| PUBLIC_DOMAIN | string | This is the URL of the server, used for logging and Host header |
| OVERWRITE_HOST | boolean | Whether to use a different Host header corrected for the proxying or not. Default is false. |
| subdomains_map | table | A table of key-value, where key is the subdomain name, and the value is the port |

## Running it

Either using:

`luvit proxyware`

or directly using:

`proxyware`

The first assumes `proxyware.lua` is in the DIR, second assumes `proxyware` is in PATH(or current dir) and Luvit runtime in `/usr/bin/luvit`.

Note that it may require root privileges to listen on some ports, such as `80`. On some machines it will also require setting your firewall rules up.

## Using it

One you have configured it and ran it, you can start the proxying. For example I have this:
Jellyfin listening on nas.local:8096, Cockpit listening on nas.local:9090, with the default configurations. Now I can open my browser up and go to `http://jellyfin.nas.local` instead of `http://nas.local:8096`, I can as well do `http://cockpit.nas.local`, etc.

The domain resolution will require further DNS setup, in my case I use the default `/etc/hosts` with `dnsmasq` as the DNS server on Linux.

### Again, this is for my personal use.

Although you are welcome to use it, fork it, or maybe contribute.
