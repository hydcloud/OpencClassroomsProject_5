frontend http_front
    bind *:80
    default_backend webservers

backend webservers
    balance roundrobin

    option httpchk GET /
    http-check expect status 200

    server web1 ${webserver1_ip}:80 check inter 5s fall 3 rise 2
    server web2 ${webserver2_ip}:80 check inter 5s fall 3 rise 2

listen stats
    bind *:8404
    mode http
    stats enable
    stats uri /stats
    stats refresh 10s
    stats auth admin:haproxy
