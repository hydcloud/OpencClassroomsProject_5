# Exercice 3 — Configuration des Health Checks HAProxy

## 1. Objectif

L'objectif est de configurer HAProxy afin qu'il :

- répartisse les requêtes entre deux serveurs applicatifs avec **Round Robin** ;
- vérifie régulièrement leur état de santé ;
- retire automatiquement un serveur défaillant de la répartition ;
- continue à servir l'application grâce au serveur restant ;
- réintègre automatiquement un serveur lorsqu'il redevient fonctionnel.

Architecture mise en place :

```text
                         ┌──► Webserver 1 ──► Docker ──► nginxdemos/hello
                         │
Client ──► HAProxy ──────┤
                         │
                         └──► Webserver 2 ──► Docker ──► nginxdemos/hello
```

L'infrastructure comporte donc **3 instances EC2** : une instance HAProxy et deux serveurs applicatifs.

## 2. Configuration du Round Robin

Le fichier HAProxy est généré à partir du template Terraform `haproxy.cfg.tpl`.

```haproxy
frontend http_front
    bind *:80
    default_backend webservers

backend webservers
    balance roundrobin

    option httpchk GET /
    http-check expect status 200

    server web1 ${webserver1_ip}:80 check inter 5s fall 3 rise 2
    server web2 ${webserver2_ip}:80 check inter 5s fall 3 rise 2
```

La directive `balance roundrobin` distribue les requêtes à tour de rôle :

```text
Requête 1 → web1
Requête 2 → web2
Requête 3 → web1
Requête 4 → web2
...
```

## 3. Configuration des Health Checks

Nous avons choisi une **sonde HTTP de niveau 7** plutôt qu'une simple vérification TCP :

```haproxy
option httpchk GET /
http-check expect status 200
```

HAProxy effectue une requête `GET /` et considère que le service est fonctionnel lorsqu'il obtient un code **HTTP 200**.

Chaque serveur est déclaré ainsi :

```haproxy
server web1 ${webserver1_ip}:80 check inter 5s fall 3 rise 2
```

- `check` : active le health check ;
- `inter 5s` : contrôle toutes les 5 secondes ;
- `fall 3` : 3 échecs consécutifs pour déclarer le serveur DOWN ;
- `rise 2` : 2 contrôles réussis consécutifs pour déclarer le serveur UP.

L'utilisation de `fall 3` limite les fausses alertes dues à une erreur ponctuelle.

## 4. Génération automatique avec Terraform

Les adresses privées des deux serveurs sont récupérées directement depuis les ressources Terraform :

```hcl
locals {
  haproxy_config = templatefile("${path.module}/haproxy.cfg.tpl", {
    webserver1_ip = aws_instance.webserver[0].private_ip
    webserver2_ip = aws_instance.webserver[1].private_ip
  })
}
```

Le fichier généré est envoyé sur l'instance HAProxy :

```hcl
provisioner "file" {
  content     = local.haproxy_config
  destination = "/tmp/haproxy.cfg"
}
```

Puis installé et HAProxy redémarré :

```hcl
provisioner "remote-exec" {
  inline = [
    "sudo cp /tmp/haproxy.cfg /etc/haproxy/haproxy.cfg",
    "sudo haproxy -c -f /etc/haproxy/haproxy.cfg",
    "sudo systemctl restart haproxy",
    "sudo systemctl enable haproxy"
  ]
}
```

Cela permet de reconstruire automatiquement la configuration lors de la création d'une nouvelle instance HAProxy.

## 5. Problème rencontré avec le template

Lors du premier déploiement, HAProxy refusait la configuration :

```text
Missing LF on last line
file might have been truncated
Fatal errors found in configuration
```

Le fichier `haproxy.cfg.tpl` possédait des fins de ligne Windows et il manquait un saut de ligne final.

Conversion en format Linux :

```bash
sed -i 's/\r$//' haproxy.cfg.tpl
```

Ajout du saut de ligne final :

```bash
sed -i -e '$a\' haproxy.cfg.tpl
```

Vérification :

```bash
tail -c 1 haproxy.cfg.tpl | od -An -t x1
```

Résultat attendu :

```text
0a
```

`0a` correspond au caractère **LF**.

## 6. Test de panne d'un serveur applicatif

Pour identifier puis arrêter un conteneur :

```bash
sudo docker ps -a
sudo docker stop <nom_ou_id_du_conteneur>
```

Depuis l'instance HAProxy, test direct du serveur arrêté :

```bash
curl -I http://172.31.21.83
```

Résultat :

```text
curl: (7) Failed to connect to 172.31.21.83 port 80:
Couldn't connect to server
```

Test du second serveur :

```bash
curl -I http://172.31.21.12
```

Résultat :

```text
HTTP/1.1 200 OK
Server: nginx/1.29.1
```

Nous avions donc bien un serveur indisponible et un serveur fonctionnel.

## 7. Vérification de la continuité de service

Nous avons envoyé **10 requêtes directement à HAProxy** :

```bash
for i in {1..10}; do
  curl -s -o /dev/null \
  -w "Requête $i : HTTP %{http_code}\n" \
  http://localhost
done
```

Résultat :

```text
Requête 1 : HTTP 200
Requête 2 : HTTP 200
Requête 3 : HTTP 200
Requête 4 : HTTP 200
Requête 5 : HTTP 200
Requête 6 : HTTP 200
Requête 7 : HTTP 200
Requête 8 : HTTP 200
Requête 9 : HTTP 200
Requête 10 : HTTP 200
```

Malgré l'arrêt de l'un des deux serveurs applicatifs, **100 % des requêtes ont continué à fonctionner**. HAProxy avait automatiquement retiré le serveur défaillant de la répartition.

## 8. Vérification de la détection de panne

Consultation des journaux HAProxy :

```bash
sudo journalctl -u haproxy --since "5 minutes ago"
```

HAProxy a signalé :

```text
Server webservers/web1 is DOWN,
reason: Layer4 connection problem,
info: "Connection refused"
```

Cela confirme que le serveur a été automatiquement considéré comme **DOWN** après l'arrêt de son service. Le trafic est alors envoyé uniquement vers le serveur encore disponible.

## 9. Test de réintégration du serveur

Le conteneur arrêté a été redémarré :

```bash
sudo docker ps -a
sudo docker start <nom_ou_id_du_conteneur>
```

Puis les logs HAProxy ont été consultés :

```bash
sudo journalctl -u haproxy --since "5 minutes ago"
```

HAProxy a indiqué :

```text
Server webservers/web1 is UP,
reason: Layer7 check passed,
code: 200
```

Le message **`Layer7 check passed`** confirme que la sonde HTTP fonctionne. Avec `rise 2`, HAProxy attend deux contrôles réussis avant de réintégrer le serveur.

## 10. Conclusion

Le fonctionnement attendu de l'exercice a été validé :

```text
2 backends disponibles
        ↓
Round Robin
        ↓
Panne de web1
        ↓
Health checks HTTP
        ↓
web1 déclaré DOWN
        ↓
Trafic envoyé uniquement vers web2
        ↓
Service toujours disponible
        ↓
Redémarrage de web1
        ↓
HTTP 200 détecté
        ↓
web1 déclaré UP
        ↓
Réintégration automatique
        ↓
Round Robin rétabli
```

La configuration répond ainsi aux trois objectifs essentiels : **répartition de charge, détection automatique des défaillances et continuité de service**.
