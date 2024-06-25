provider "aws" {
  region = "us-west-1"
}

data "aws_ami" "ubuntu_24_04" {
  most_recent = true
  owners      = ["099720109477"] # Canonical

  filter {
    name   = "name"
    values = ["ubuntu/images/hvm-ssd/ubuntu-noble-24.04-amd64-server-*"]
  }

  filter {
    name   = "virtualization-type"
    values = ["hvm"]
  }
}

resource "aws_vpc" "main" {
  cidr_block           = "10.0.0.0/16"
  enable_dns_hostnames = true

  tags = {
    Name = "main-vpc"
  }
}

resource "aws_internet_gateway" "main" {
  vpc_id = aws_vpc.main.id

  tags = {
    Name = "main-igw"
  }
}

resource "aws_subnet" "public" {
  vpc_id                  = aws_vpc.main.id
  cidr_block              = "10.0.1.0/24"
  map_public_ip_on_launch = true

  tags = {
    Name = "public-subnet"
  }
}

resource "aws_subnet" "private" {
  vpc_id     = aws_vpc.main.id
  cidr_block = "10.0.2.0/24"

  tags = {
    Name = "private-subnet"
  }
}

resource "aws_route_table" "public" {
  vpc_id = aws_vpc.main.id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.main.id
  }

  tags = {
    Name = "public-rt"
  }
}

resource "aws_route_table_association" "public" {
  subnet_id      = aws_subnet.public.id
  route_table_id = aws_route_table.public.id
}

resource "aws_eip" "nat" {
  domain = "vpc"
}

resource "aws_nat_gateway" "main" {
  allocation_id = aws_eip.nat.id
  subnet_id     = aws_subnet.public.id

  tags = {
    Name = "main-nat-gw"
  }
}

resource "aws_route_table" "private" {
  vpc_id = aws_vpc.main.id

  route {
    cidr_block     = "0.0.0.0/0"
    nat_gateway_id = aws_nat_gateway.main.id
  }

  tags = {
    Name = "private-rt"
  }
}

resource "aws_route_table_association" "private" {
  subnet_id      = aws_subnet.private.id
  route_table_id = aws_route_table.private.id
}

resource "aws_security_group" "jumpbox" {
  name        = "jumpbox-sg"
  description = "Security group for jumpbox"
  vpc_id      = aws_vpc.main.id

  ingress {
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = ["157.46.90.139/32"]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

resource "aws_security_group" "kubernetes" {
  name        = "kubernetes-sg"
  description = "Security group for Kubernetes nodes"
  vpc_id      = aws_vpc.main.id

  ingress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    self        = true
    description = "Allow all internal traffic"
  }

  ingress {
    from_port       = 22
    to_port         = 22
    protocol        = "tcp"
    security_groups = [aws_security_group.jumpbox.id]
    description     = "Allow SSH from jumpbox"
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

resource "aws_instance" "jumpbox" {
  ami           = data.aws_ami.ubuntu_24_04.id
  instance_type = "t2.micro"
  key_name      = "uday1"
  subnet_id     = aws_subnet.public.id

  vpc_security_group_ids = [aws_security_group.jumpbox.id]

  tags = {
    Name = "jumpbox"
  }
}

resource "aws_instance" "kubernetes" {
  count         = 3
  ami           = data.aws_ami.ubuntu_24_04.id
  instance_type = "t2.medium"
  key_name      = "uday1"
  subnet_id     = aws_subnet.private.id

  vpc_security_group_ids = [aws_security_group.kubernetes.id]

  tags = {
    Name = "kubernetes-${count.index}"
  }
}

resource "aws_ebs_volume" "kubernetes" {
  count             = 3
  availability_zone = aws_instance.kubernetes[0].availability_zone
  size              = 20

  tags = {
    Name = "kubernetes-ebs-${count.index}"
  }
}

resource "aws_volume_attachment" "kubernetes" {
  count       = 3
  device_name = "/dev/sdf"
  volume_id   = aws_ebs_volume.kubernetes[count.index].id
  instance_id = aws_instance.kubernetes[count.index].id
}

resource "null_resource" "kubernetes_setup" {
  count = 3

  connection {
    type                = "ssh"
    user                = "ubuntu"
    host                = aws_instance.kubernetes[count.index].private_ip
    private_key         = file("~/.ssh/uday1.pem")
    bastion_host        = aws_instance.jumpbox.public_ip
    bastion_user        = "ubuntu"
    bastion_private_key = file("~/.ssh/uday1.pem")
  }

  provisioner "remote-exec" {
    inline = [
      "sudo apt-get update",
      "sudo apt-get install -y apt-transport-https ca-certificates curl software-properties-common",
      "curl -fsSL https://download.docker.com/linux/ubuntu/gpg | sudo apt-key add -",
      "sudo add-apt-repository \"deb [arch=amd64] https://download.docker.com/linux/ubuntu $(lsb_release -cs) stable\"",
      "sudo apt-get update",
      "sudo apt-get install -y docker-ce",
      "sudo systemctl enable docker",
      "sudo systemctl start docker",
      "curl -s https://packages.cloud.google.com/apt/doc/apt-key.gpg | sudo apt-key add -",
      "echo \"deb https://apt.kubernetes.io/ kubernetes-xenial main\" | sudo tee /etc/apt/sources.list.d/kubernetes.list",
      "sudo apt-get update",
      "sudo apt-get install -y kubelet kubeadm kubectl",
      "sudo apt-mark hold kubelet kubeadm kubectl",
    ]
  }
}

resource "null_resource" "kubernetes_init" {
  depends_on = [null_resource.kubernetes_setup]

  connection {
    type                = "ssh"
    user                = "ubuntu"
    host                = aws_instance.kubernetes[0].private_ip
    private_key         = file("~/.ssh/uday1.pem")
    bastion_host        = aws_instance.jumpbox.public_ip
    bastion_user        = "ubuntu"
    bastion_private_key = file("~/.ssh/uday1.pem")
  }

  provisioner "remote-exec" {
    inline = [
      "sudo kubeadm init --pod-network-cidr=10.244.0.0/16",
      "mkdir -p $HOME/.kube",
      "sudo cp -i /etc/kubernetes/admin.conf $HOME/.kube/config",
      "sudo chown $(id -u):$(id -g) $HOME/.kube/config",
      "kubectl apply -f https://raw.githubusercontent.com/coreos/flannel/master/Documentation/kube-flannel.yml",
    ]
  }
}

resource "null_resource" "kubernetes_join" {
  count      = 2
  depends_on = [null_resource.kubernetes_init]

  connection {
    type                = "ssh"
    user                = "ubuntu"
    host                = aws_instance.kubernetes[count.index + 1].private_ip
    private_key         = file("~/.ssh/uday1.pem")
    bastion_host        = aws_instance.jumpbox.public_ip
    bastion_user        = "ubuntu"
    bastion_private_key = file("~/.ssh/uday1.pem")
  }

  provisioner "remote-exec" {
    inline = [
      "sudo $(ssh -i ~/.ssh/uday1.pem ubuntu@${aws_instance.kubernetes[0].private_ip} 'kubeadm token create --print-join-command')",
    ]
  }
}

output "jumpbox_public_ip" {
  value = aws_instance.jumpbox.public_ip
}

output "kubernetes_private_ips" {
  value = aws_instance.kubernetes[*].private_ip
}