terraform {
  backend "s3" {
    bucket = "${var.vpc_remote_state_s3_bucket}"
    key    = "${var.vpc_remote_state_s3_key}"
    region = "${var.vpc_remote_state_s3_region}"
  }
}

# Create a VPC to launch our instances into
resource "aws_vpc" "main" {
  cidr_block = "10.0.0.0/16"

  tags {
   Name = "${data.template_file.cluster-name.rendered}-vpc"
   cluster = "${data.template_file.cluster-name.rendered}"
  } 
  
  lifecycle {
    ignore_changes = ["tags.Name", "tags.cluster"]
  }
}

# Create an internet gateway to give our subnet access to the outside world
resource "aws_internet_gateway" "main" {
  vpc_id = "${aws_vpc.main.id}"
}

# Grant the VPC internet access on its main route table
resource "aws_route" "internet_access" {
  route_table_id         = "${aws_vpc.main.main_route_table_id}"
  destination_cidr_block = "0.0.0.0/0"
  gateway_id             = "${aws_internet_gateway.main.id}"
}

# Create a subnet to launch public nodes into
resource "aws_subnet" "public" {
  vpc_id                  = "${aws_vpc.main.id}"
  cidr_block              = "10.0.0.0/22"
  map_public_ip_on_launch = true
}

# Create a subnet to launch slave private node into
resource "aws_subnet" "private" {
  vpc_id                  = "${aws_vpc.main.id}"
  cidr_block              = "10.0.4.0/22"
  map_public_ip_on_launch = true
}
