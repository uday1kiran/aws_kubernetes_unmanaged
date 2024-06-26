provider "aws" {
  region = "us-west-1"
}

data "aws_ami" "ubuntu_24_04" {
  most_recent = true

  filter {
    name   = "name"
    values = ["ubuntu/images/hvm-ssd*/ubuntu-*-24.04-amd64-server-*"]
  }

  filter {
    name   = "virtualization-type"
    values = ["hvm"]
  }

  owners = ["099720109477"]
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
    cidr_blocks = ["152.58.221.76/32"]
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
  depends_on = [aws_internet_gateway.main]
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

resource "null_resource" "kubernetes_setup_prereq" {
  count = 3

  connection {
    type                = "ssh"
    user                = "ubuntu"
    host                = aws_instance.kubernetes[count.index].private_ip
    private_key         = file("uday1.pem")
    bastion_host        = aws_instance.jumpbox.public_ip
    bastion_user        = "ubuntu"
    bastion_private_key = file("uday1.pem")
  }

  provisioner "remote-exec" {
          inline = [
      "sudo apt-get -y update",
      "sudo apt-get install -y curl gnupg2 software-properties-common apt-transport-https ca-certificates",
      "sudo swapoff -a",
      "sudo sed -i '/ swap / s/^\\(.*\\)$/#\\1/g' /etc/fstab",
      "sudo tee /etc/modules-load.d/k8s.conf <<EOF\noverlay\nbr_netfilter\nEOF",
      "sudo tee /etc/sysctl.d/kubernetes.conf <<EOT\nnet.bridge.bridge-nf-call-ip6tables = 1\nnet.bridge.bridge-nf-call-iptables = 1\nnet.ipv4.ip_forward = 1\nEOT",
      "sudo modprobe overlay",
      "sudo modprobe br_netfilter",
      "sudo sysctl --system",
      "sudo curl -fsSL https://download.docker.com/linux/ubuntu/gpg | sudo gpg --dearmour -o /etc/apt/trusted.gpg.d/containerd.gpg",
      "sudo add-apt-repository -y \"deb [arch=amd64] https://download.docker.com/linux/ubuntu $(lsb_release -cs) stable\"",
      "sudo apt-get update && sudo apt-get install -y containerd.io",
      "containerd config default | sudo tee /etc/containerd/config.toml >/dev/null 2>&1",
      "sudo sed -i 's/SystemdCgroup = false/SystemdCgroup = true/g' /etc/containerd/config.toml",
      "sudo systemctl restart containerd",
      "sudo curl -fsSL https://pkgs.k8s.io/core:/stable:/v1.30/deb/Release.key | sudo gpg --yes --dearmor -o /etc/apt/keyrings/k8s.gpg",
      "echo 'deb [signed-by=/etc/apt/keyrings/k8s.gpg] https://pkgs.k8s.io/core:/stable:/v1.30/deb/ /' | sudo tee /etc/apt/sources.list.d/k8s.list",
      "sudo apt-get update",
      "sudo apt-get install -y kubelet kubeadm kubectl"
    ]
  }
}

resource "null_resource" "kubernetes_setup" {
  depends_on = [null_resource.kubernetes_setup_prereq]
  count = 3

  connection {
    type                = "ssh"
    user                = "ubuntu"
    host                = aws_instance.kubernetes[count.index].private_ip
    private_key         = file("uday1.pem")
    bastion_host        = aws_instance.jumpbox.public_ip
    bastion_user        = "ubuntu"
    bastion_private_key = file("uday1.pem")
  }

  provisioner "remote-exec" {
    inline = [
      "sudo apt-get update"
    #   "sudo apt-get install -y apt-transport-https ca-certificates curl software-properties-common",
    #   "curl -fsSL https://download.docker.com/linux/ubuntu/gpg | sudo apt-key add -",
    #   "sudo add-apt-repository \"deb [arch=amd64] https://download.docker.com/linux/ubuntu $(lsb_release -cs) stable\"",
    #   "sudo apt-get update",
    #   "sudo apt-get install -y docker-ce",
    #   "sudo systemctl enable docker",
    #   "sudo systemctl start docker",
    #   "curl -s https://packages.cloud.google.com/apt/doc/apt-key.gpg | sudo apt-key add -",
    #   "echo \"deb https://apt.kubernetes.io/ kubernetes-xenial main\" | sudo tee /etc/apt/sources.list.d/kubernetes.list",
    #   "sudo apt-get update",
    #   "sudo apt-get install -y kubelet kubeadm kubectl",
    #   "sudo apt-mark hold kubelet kubeadm kubectl",
    ]
  }
}

resource "null_resource" "kubernetes_init" {
  depends_on = [null_resource.kubernetes_setup]

  connection {
    type                = "ssh"
    user                = "ubuntu"
    host                = aws_instance.kubernetes[0].private_ip
    private_key         = file("uday1.pem")
    bastion_host        = aws_instance.jumpbox.public_ip
    bastion_user        = "ubuntu"
    bastion_private_key = file("uday1.pem")
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

# resource "null_resource" "wait_for_jumpbox" {
#   depends_on = [aws_instance.jumpbox]

#   provisioner "local-exec" {
#     command = <<-EOT
#       #!/bin/bash
#       echo "Waiting for 60 seconds before attempting to connect..."
#       sleep 60
#       for i in {1..30}; do
#         echo "Attempt $i to connect to jumpbox..."
#         if ssh -o StrictHostKeyChecking=no -o ConnectTimeout=5 -i uday1.pem ubuntu@${aws_instance.jumpbox.public_ip} echo 'Jumpbox is ready'; then
#           echo "Successfully connected to jumpbox"
#           exit 0
#         fi
#         echo "Failed to connect, retrying in 10 seconds..."
#         sleep 10
#       done
#       echo "Failed to connect to jumpbox after 30 attempts"
#       exit 1
#     EOT
#     interpreter = ["/bin/bash", "-c"]
#   }
# }

resource "null_resource" "kubernetes_join" {
  count      = 2
  depends_on = [null_resource.kubernetes_init, aws_instance.jumpbox]

  connection {
    type                = "ssh"
    user                = "ubuntu"
    host                = aws_instance.kubernetes[count.index + 1].private_ip
    private_key         = file("uday1.pem")
    bastion_host        = aws_instance.jumpbox.public_ip
    bastion_user        = "ubuntu"
    bastion_private_key = file("uday1.pem")
    agent               = false
  }

  provisioner "file" {
    source      = "uday1.pem"
    destination = "/home/ubuntu/.ssh/uday1.pem"
  }

  provisioner "remote-exec" {
    inline = [
      "chmod 400 ~/.ssh/uday1.pem",
      "ssh-keyscan -H ${aws_instance.kubernetes[0].private_ip} >> ~/.ssh/known_hosts",
      "join_command=$(ssh -o StrictHostKeyChecking=no -i ~/.ssh/uday1.pem ubuntu@${aws_instance.kubernetes[0].private_ip} 'sudo kubeadm token create --print-join-command')",
      "echo $join_command",
      "sudo $join_command",
    ]
  }
}


resource "null_resource" "jumpbox_setup" {
  depends_on = [aws_instance.jumpbox, null_resource.kubernetes_init]

  connection {
    type        = "ssh"
    user        = "ubuntu"
    host        = aws_instance.jumpbox.public_ip
    private_key = file("uday1.pem")
  }

  provisioner "remote-exec" {
    inline = [
      "sudo apt-get update",
      "sudo apt-get install -y apt-transport-https ca-certificates curl",
      "curl -s https://packages.cloud.google.com/apt/doc/apt-key.gpg | sudo apt-key add -",
      "echo \"deb https://apt.kubernetes.io/ kubernetes-xenial main\" | sudo tee /etc/apt/sources.list.d/kubernetes.list",
      "sudo apt-get update",
      "sudo apt-get install -y kubectl",
      "mkdir -p $HOME/.kube",
    ]
  }
}

resource "null_resource" "copy_kubeconfig" {
  depends_on = [null_resource.jumpbox_setup]

  connection {
    type        = "ssh"
    user        = "ubuntu"
    host        = aws_instance.jumpbox.public_ip
    private_key = file("uday1.pem")
    agent       = false
  }

  provisioner "file" {
    source      = "uday1.pem"
    destination = "/home/ubuntu/.ssh/uday1.pem"
  }

  provisioner "remote-exec" {
    inline = [
      "chmod 400 ~/.ssh/uday1.pem",
      "ssh-keyscan -H ${aws_instance.kubernetes[0].private_ip} >> ~/.ssh/known_hosts",
      "scp -o StrictHostKeyChecking=no -i ~/.ssh/uday1.pem ubuntu@${aws_instance.kubernetes[0].private_ip}:.kube/config ~/.kube/config",
      "sed -i 's/https:\\/\\/.*:/https:\\/\\/${aws_instance.kubernetes[0].private_ip}:/g' ~/.kube/config",
    ]
  }
}

output "jumpbox_public_ip" {
  value = aws_instance.jumpbox.public_ip
}

output "kubernetes_private_ips" {
  value = aws_instance.kubernetes[*].private_ip
}
