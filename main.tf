provider "aws" {
  region = "eu-west-1"
}

resource "aws_key_pair" "key" {
  key_name   = "ledger-key-pair"
  public_key = file("~/.ssh/LedgerKeyPair.pem.pub")
}

resource "aws_security_group" "ledger_app_sg" {
  name_prefix = "ledger-app-sg"

  ingress {
    description = "Allow HTTP traffic"
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  ingress {
    description = "Allow MySQL traffic (optional, for remote DB access)"
    from_port   = 3306
    to_port     = 3306
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  ingress {
    description = "Allow SSH traffic"
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  egress {
    description = "Allow all outbound traffic"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

resource "aws_instance" "ledger_app" {
  ami           = "ami-0a094c309b87cc107"
  instance_type = "t2.micro"
  key_name      = aws_key_pair.key.key_name

  security_groups = [aws_security_group.ledger_app_sg.name]

  user_data = <<-EOF
    #!/bin/bash
    # Update and install necessary packages
    yum update -y
    yum install -y docker git

    # Start Docker and enable it to start on boot
    systemctl start docker
    systemctl enable docker

    # Add the ec2-user to the docker group
    usermod -aG docker ec2-user

    # Install Docker Compose
    curl -L "https://github.com/docker/compose/releases/latest/download/docker-compose-\$(uname -s)-\$(uname -m)" -o /usr/local/bin/docker-compose
    chmod +x /usr/local/bin/docker-compose

    # Clone the Laravel project repository
    git clone https://github.com/bulutaysarac/LedgerApp.git /var/www/laravel

    # Navigate to the project directory and start Docker containers
    cd /var/www/laravel
    /usr/local/bin/docker-compose up -d
  EOF

  tags = {
    Name = "ledger-app-server"
  }
}

output "instance_public_ip" {
  value = aws_instance.ledger_app.public_ip
}

output "instance_public_dns" {
  value = aws_instance.ledger_app.public_dns
}