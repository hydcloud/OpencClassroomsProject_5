terraform {
  required_providers {
    aws = {
      source = "hashicorp/aws"
    }
  }
}

provider "aws" {
  region  = "eu-west-3"
  profile = "terraform-user"
}

data "aws_ami" "amazon_linux" {
  most_recent = true
  owners      = ["amazon"]

  filter {
    name   = "name"
    values = ["al2023-ami-2023.*-kernel-*-x86_64"]
  }
}

resource "aws_key_pair" "ansible" {
  key_name   = "terraform-ansible"
  public_key = file(pathexpand("~/.ssh/terraform-aws.pub"))
}

resource "aws_instance" "server" {
  ami           = data.aws_ami.amazon_linux.id
  instance_type = "t3.micro"

  key_name = aws_key_pair.ansible.key_name

  vpc_security_group_ids = [
    aws_security_group.ansible_ssh.id
  ]

  tags = {
    Name = "OC-Projet4"
  }
}

resource "aws_security_group" "ansible_ssh" {
  name        = "terraform-ansible-ssh"
  description = "Autoriser SSH depuis mon IP publique"

  ingress {
    description = "SSH depuis mon IP"
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = var.my_public_ips
  }

  ingress {
    description     = "SSH"
    from_port       = 22
    to_port         = 22
    protocol        = "tcp"
    prefix_list_ids = ["pl-0f2a97ab210dbbae1"]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  ingress {
    description = "HTTP depuis mes IP autorisees"
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = var.my_public_ips
  }
}