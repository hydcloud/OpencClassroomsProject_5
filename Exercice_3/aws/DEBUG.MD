## Pour l'accès à la console HAProxy, quelques correctifs devaient être effectués avant le déploiement via Terraform

Ajout du bloc suivant dans le fichier haproxy.cfg.tpl 

listen stats
bind *:8404
mode http
stats enable
stats uri /stats
stats refresh 10s
stats auth admin:haproxy

Ajout du bloc suivant dans le fichier main.tf : 

resource "terraform_data" "haproxy_config_deploy" {
triggers_replace = [
sha256(local.haproxy_config),
aws_instance.haproxy.id
]

connection {
type        = "ssh"
user        = "ubuntu"
private_key = tls_private_key.my_ssh_key.private_key_pem
host        = aws_instance.haproxy.public_ip
}

provisioner "file" {
content     = local.haproxy_config
destination = "/tmp/haproxy.cfg"
}

provisioner "remote-exec" {
inline = [
"sudo haproxy -c -f /tmp/haproxy.cfg",
"sudo cp /tmp/haproxy.cfg /etc/haproxy/haproxy.cfg",
"sudo systemctl reload haproxy"
]
}
}

## La console HAProxy est désormais accessible par l'URL suivante

http://100.56.233.98:8404/stats**