#!/bin/bash
env=$1
lb="juna-exer-ElasticL-JYJ71QXD431N"
region=us-west-2

#Get the number of instances attached to LB
instances_id=($(aws elb describe-load-balancers --load-balancer-name $lb --region=$region --query LoadBalancerDescriptions[].Instances[].InstanceId  --output=text))
instance_length=${#instances_id[@]}

#Check if any instance attached to LB"
if [ $instance_length == 0 ]
then
  echo "No instances attached to $lb"
  exit 1
fi
for (( j=0; j<$instance_length; j++ ))
do
instance=${instances_id[$j]}
instanceip=($(aws ec2 describe-instances --region=$region --instance-ids $instance --query Reservations[].Instances[].PublicIpAddress --output=text))
instance_pvip=($(aws ec2 describe-instances --region=$region --instance-ids $instance --query Reservations[].Instances[].PrivateIpAddress --output=text))
inst_name=($(aws ec2 describe-instances --region=$region  --instance-ids $instance --query 'Reservations[].Instances[].Tags[?Key==`Name`].Value[]' --output=text))
counter=0

#removing target from ami
echo "Removing node $inst_name from the load balancer."
echo "Instance ID of $inst_name : $instance"
aws elb deregister-instances-from-load-balancer --region=us-west-2 --load-balancer-name $lb --instances $instance --output=text
sleep 10
echo "Checking the application status"
response=`curl -s -I https://config.appliance-trial.com/testall | head -1 | awk {' print $2 '}`
echo "Application returned status : $response"
if [[ "$response" == "200" ]]
  then
    echo "Application is UP"
else
    echo "Application is DOWN"
    exit 1
fi
ami="$inst_name-`date +%d%b%y`"

#creating AMI for the instance
echo "Creating backup for $instance"
if [ $env == primary ]
then
  echo "Creating AMI with reboot :"
  aws ec2 create-image --region=$region --instance-id $instance --name "$ami" --description "Automated backup created for $instance" --output=text >/tmp/aminate.txt
elif [ $env == secondary ]
  then
  echo "Creating AMI without reboot :"
  aws ec2 create-image --region=$region --no-reboot --instance-id $instance --name "$ami" --description "Automated backup created for $instance" --output=text >/tmp/aminate.txt
else
  echo "No region $env found"
  exit 1
fi
 for i in `cat /tmp/aminate.txt`; do
  ami_nm=($(aws ec2 describe-images --region=$region --owners=201973737062 --image-ids=$i --query Images[].Name --output=text))
 echo "Created AMI : $ami_nm"
 echo  "AMI ID is  : $i"
 done
echo "Backup process completed...."
#starting system reboot

echo "Procceding to reboot instance "$inst_name""
aws ec2 reboot-instances --region=$region --instance-ids $instance
sleep 90
status=500
until [ $status -eq 200 ]; do
    echo "Application is still not up.. HTTP status: $status"
    sleep 10
    status=$(curl -s -o /dev/null -w '%{http_code}' http://$instance_pvip/testall)
    counter=`expr $counter + 1`
    if [ $counter -gt 15 ]
    then
       echo "Application is Down"
       exit 1
    fi
done
echo "Got $status. All Good!"


#Adding instance back to LB
echo "Adding $inst_name back to LB"
aws elb register-instances-with-load-balancer --region=$region --load-balancer-name $lb --instances $instance

echo "Maintenance completed for $inst_name"
done

#Removing old AMIS
echo "Fetching AMI details ...."
ami_array=($(aws ec2 describe-images --region=$region --owners=201973737062 --query Images[].ImageId --output=text))
array_length=${#ami_array[@]}
for (( i=0; i<$array_length; i++ ))
do
  image_id=${ami_array[$i]}
  image_name=($(aws ec2 describe-images --region=$region --image-ids=$image_id  --query Images[].Name --output=text))
  image_date=($(aws ec2 describe-images --region=$region --image-ids=$image_id  --query Images[].CreationDate --output=text | cut -d'T' -f1))
  imgdt=$(date -d $image_date +%s)
  current_date=$(date +%Y-%m-%d)
  todate=$(date -d $current_date +%s)
  if [[ "$todate" > "$imgdt" ]];
  then
    echo "Following AMI is found : $image_id"
    echo ""Image Name : $image_name""
    echo ""Image CreationDate : $image_date""
    aws ec2 describe-images --region=$region --image-ids $image_id | grep  "SnapshotId" | cut -d: -f2 | sed -e 's/^ "//' | cut -d, -f1 | sed -e 's/"$//' > /tmp/snap.txt
    echo  ""Following are the snapshots associated with it : `cat /tmp/snap.txt`""
    echo  "Starting the Deregister of AMI... "
    aws ec2 deregister-image --region=$region --image-id $image_id
    echo "Deleting the associated snapshots.... "
     for j in `cat /tmp/snap.txt`;do aws ec2 delete-snapshot --region=$region --snapshot-id $j ; done
     sleep 3
  else
    echo "Image $image_id is created today"
  fi
done
