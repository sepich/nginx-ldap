# LDAP auth daemon for nginx

Python multithread daemon to be used via [auth_request](http://nginx.org/en/docs/http/ngx_http_auth_request_module.html). Based on reference design [nginx-ldap-auth](https://github.com/nginxinc/nginx-ldap-auth), which was simplified and group/user restrictions were added.  

Why not compiled module [nginx-auth-ldap](https://github.com/kvspb/nginx-auth-ldap)?  
Unfortunately that one is synchronous, thus worker is locked while communicating with ldap-server and not serving other requests. And in contrast `auth_request` is async, scalable, and also support caching on nginx side (See the tests below)

### How it works?
Auth decision is made based on results of subrequest. Consider this example:
```nginx
location / {
  auth_request /auth-proxy;
  ...
}
location = /auth-proxy {
  internal;
  proxy_pass http://127.0.0.1:8888;
}
```
Request comes for `/index.html` and falls to `/` location in this case. It would not be served, but subrequest made to `http://127.0.0.1:8888` containing login:pass from original request. And then depending on subrequest response (200/401) file serving would continue.

And you guess right, it is `nginx-ldap-auth-daemon` who is listening on `127.0.0.1:8888` and actually doing LDAP requests.

### Installation
Example for Debian Jessie:
```bash
cp nginx-ldap-auth.service /etc/systemd/system/
cp nginx-ldap-auth-daemon /etc/nginx/
systemctl daemon-reload
systemctl enable nginx-ldap-auth.service
systemctl start nginx-ldap-auth.service
```
By default LDAP connection params are read from `/etc/pam_ldap.conf`, so daemon is started as `root` and then drops privileges. To specify another file, use `-c` switch in `.service` unit file:
```
$ /etc/nginx/nginx-ldap-auth-daemon -h
usage: nginx-ldap-auth-daemon [-h] [--host HOST] [-p PORT] [-c CONFIG]

Simple Nginx LDAP authentication helper.

optional arguments:
  -h, --help            show this help message and exit
  --host HOST           host to bind (Default: localhost)
  -p PORT, --port PORT  port to bind (Default: 8888)
  -c CONFIG, --config CONFIG
                        config with LDAP creds (Default: /etc/pam_ldap.conf)
```
Only these 5 values are used from [the config](https://linux.die.net/man/5/pam_ldap) (rest is skipped):
```nginx
host 192.168.0.1 192.168.0.2
base DC=test,DC=local
binddn ldapproxy@test
bindpw Pa$$w0rd
ssl on
```
Multiple hosts could be specified, daemon would try reach all of them in case of error, before answering 500.

### Usage
You can use such headers on nginx side:  
`X-Ldap-Realm` - Banner, default is 'Authorization required'  
`X-Ldap-Allowed-Usr` - Allow only these users (comma delimited)  
`X-Ldap-Allowed-Grp` - Allow only these groups (comma delimited). Both AD Group membership and UNIX Group is taken into account.  
If no `X-Ldap-Allowed-Usr`/`X-Ldap-Allowed-Grp` specified - any user with valid password is accepted.
User and Groups names are case insensitive.

Here is example of adding auth for [aptly](https://www.aptly.info/doc/api/) REST API with separation of ACLs per URI:
```nginx
proxy_cache_path /var/cache/nginx/auth_cache keys_zone=auth_cache:10m;
upstream aptly {
    server localhost:8080;
}
server {
    set $user '';
    set $group '';

    location / {
        auth_request /auth-proxy;
        proxy_pass http://aptly/;

        location ~ ^/api/(repos|publish)/repo1 {
            set $group "Repo1 Administrators";
            proxy_pass http://aptly/$uri;
        }

        location ~ ^/api/(repos|publish)/repo2 {
            set $user "User2, User3";
            proxy_pass http://aptly/$uri;
        }
    }

    location = /auth-proxy {
        internal;
        proxy_pass http://127.0.0.1:8888;
        proxy_pass_request_body off;
        proxy_set_header Content-Length "";
        proxy_set_header X-Ldap-Realm "Aptly API auth";
        proxy_set_header X-Ldap-Allowed-Usr $user;
        proxy_set_header X-Ldap-Allowed-Grp $group;
        proxy_cache auth_cache;
        proxy_cache_valid 200 15m;
        proxy_cache_key "$http_authorization$user$group";
    }
}
```
In this case effective permissions are:  
`/api/version` - any LDAP user with valid password  
`/api/repos/repo1` - only members of `Repo1 Administrators` LDAP group  
`/api/publish/repo2` - only users `User2` and `User3`  
Also, successfull login attempts are cached for 15min.

### Tests
Base timing: single request to auth-daemon takes about half a second to communicate with LDAP
```
$ time curl -i -u user:pass 127.0.0.1:8888
HTTP/1.0 200 OK
Server: BaseHTTP/0.3 Python/2.7.9
Date: Fri, 10 Mar 2017 21:53:46 GMT

real    0m0.549s
user    0m0.004s
sys     0m0.000s
```

Further tests are done with default nginx configuration having `worker_processes  1;`  
20 concurrent connections, 200 requests in total via ApacheBench command:  
`ab -n 200 -c 20 -A user:pass http://127.0.0.1/`

Let's start with compiled module `nginx-auth-ldap`
```
Server Software:        nginx/1.11.10
Server Hostname:        127.0.0.1
Server Port:            80

Document Path:          /
Document Length:        612 bytes

Concurrency Level:      20
Time taken for tests:   89.331 seconds
Complete requests:      200
Failed requests:        0
Total transferred:      169200 bytes
HTML transferred:       122400 bytes
Requests per second:    2.24 [#/sec] (mean)
Time per request:       8933.053 [ms] (mean)
Time per request:       446.653 [ms] (mean, across all concurrent requests)
Transfer rate:          1.85 [Kbytes/sec] received

Connection Times (ms)
              min  mean[+/-sd] median   max
Connect:        0    0   0.1      0       1
Processing:  4687 8721 758.9   8931    8946
Waiting:     4687 8721 758.9   8931    8946
Total:       4688 8721 758.8   8931    8946
```
2req/s = 0.5s per request showing one worker blocking connection. (All 20 simultaneous connections are waiting in one queue) Note that there is no way to speed this up via caching on nginx side.

Results for `nginx-ldap-auth-daemon` in multi-thread mode (default) with no cache on nginx side:
```
Concurrency Level:      20
Time taken for tests:   6.023 seconds
Complete requests:      200
Failed requests:        0
Requests per second:    33.20 [#/sec] (mean)
Time per request:       602.348 [ms] (mean)
Time per request:       30.117 [ms] (mean, across all concurrent requests)
```
20 connections for 10 requests each by 0.5s ~= 5sec, and we have 6s. Scalable.

And with cache enabled:
```
Concurrency Level:      20
Time taken for tests:   0.030 seconds
Complete requests:      200
Failed requests:        0
Requests per second:    6751.51 [#/sec] (mean)
Time per request:       2.962 [ms] (mean)
Time per request:       0.148 [ms] (mean, across all concurrent requests)
```
