# aws_backup_cleanup

The ultimate goal of this script is to take the backup of an ec2 instance and to delete older AMI including snapshots associated with it...

**List of the permissions needed for the IAM role.**
```
For ec2 instance:

Actions                   Access level

DescribeInstances         List
CreateImage               Write
CreateSnapshot            Write
DescribeImages            List
DeleteSnapshot            Write
DeregisterImage           Write

For ELB:

Actions                                Access level

DeregisterInstancesFromLoadBalancer    Write
RegisterInstancesWithLoadBalancer      Write
DescribeLoadBalancerAttributes         Read

```

**Procedure for backup and cleanup:**

1) Remove a node from the load balancer.
2) Create an AMI from the node (with reboot for primary and without reboot for secondary).
3) Reboot the machine. Wait for the node "/testall" endpoint to return "OK"
4) Add the node back to the load balancer.
5) Remove the old backups and AMIs along with the EBS volume snapshots that are no longer needed.

First of all,we need to pass an argument while executing the script. If the argument passed is primary, then the complete action will be performed on primary nodes or if it is "secondary" then the action will be carried out on the secondary region.

**1.Remove a node from the load balancer.**

We can get the list of instances attached to the Lb using the command "aws elb describe-load-balancers". Create an array which holds the "instance-id" of the instances. A "for" loop in shell script can be used to perform maintenance on each instance one at a time. 

*Command:*
```
#Get the number of instances attached to LB
instances_id=($(aws elb describe-load-balancers --load-balancer-name $lb  --query LoadBalancerDescriptions[].Instances[].InstanceId  --output=text))
```
Before proceeding to deregister AMI from LB. We need to check the number of instances attached to the LB. If it is zero the script will exit saying "No instances attached to LB".

*Command:*
```
instance_length=${#instances_id[@]}
if [ $instance_length == 0 ]
then
  echo "No instances attached to $lb"
  exit 1
fi
```
Before proceeding with the backup proccess. We need to collect some metadata of the instance for which backup is being taken, such as Instance name, Instance IP etc.. so that we can use these values throughout the script.

*Command:*
```
instanceip=($(aws ec2 describe-instances --region=$region --instance-ids $instance --query Reservations[].Instances[].PublicIpAddress --output=text))
instance_pvip=($(aws ec2 describe-instances --region=$region --instance-ids $instance --query Reservations[].Instances[].PrivateIpAddress --output=text))
inst_name=($(aws ec2 describe-instances --region=$region  --instance-ids $instance --query 'Reservations[].Instances[].Tags[?Key==`Name`].Value[]' --output=text))
```

Now,if the instance count is non-zero, then the script proceeds to deregister instance from LB.

*Command:*
```
aws elb deregister-instances-from-load-balancer --load-balancer-name $lb --instances $instance --output=text
```
**Sample output:**
```
Removing node a0-3 from the load balancer.
Instance ID of a0-3 : i-02f49c362d2001568
INSTANCES	i-0fbeee24a8cb7b59f
INSTANCES	i-047c82da7df050d1e
```
Once the instance is taken out of the LB, we need to check the application status and make sure that the application is loading fine. We can get the http status using "curl" as given below.

*Command:*
```
curl -s -I https://config.appliance-trial.com/testall | head -1 | awk {' print $2 '}
200
```
**2.Create an AMI from the node (with reboot for primary and without reboot for secondary).**

Next is to create an AMI for the instance which has been taken out of LB now. If this is a node in primary environment, AMI should be created with reboot. By default, Amazon EC2 attempts to shut down and reboot the instance before creating the image. You can use --no-reboot for secondary environment to eliminate the restart. The exit status of the AMI creation is captured and the process fails if exit status is non-zer0.

*Command:*
```
echo "Creating backup for $instance"
exit_status=1
if [ $env == primary ]
then
  echo "Creating AMI with reboot :"
  aws ec2 create-image --region=$region --instance-id $instance --name "$ami" --description "Automated backup created for $instance" --output=text >/tmp/aminate.txt 2>> /dev/null && exit_status=$?;
elif [ $env == secondary ]
  then
  echo "Creating AMI without reboot :"
  aws ec2 create-image --region=$region --no-reboot --instance-id $instance --name "$ami" --description "Automated backup created for $instance" --output=text >/tmp/aminate.txt 2>> /dev/null && exit_status=$?;
else
  echo "No region $env found"
  exit 1
fi
if [ $exit_status -gt 0 ]
then
  echo "Failed to create AMI"
  exit 1
fi
```
**Sample output:**
```
Creating backup for i-02f49c362d2001568 
Creating AMI with reboot :
Created AMI : AMI2-a0-3-19Sep18
AMI ID is  : ami-0d532b21d3f3d5d93
Backup process completed....
```
**3.Update and reboot the machine. Wait for the node "/testall" endpoint to return "OK".**

Now we need to reboot the instance. We can use "aws ec2 reboot-instances" for rebooting an instance.

*Command:*
```
aws ec2 reboot-instances --region=$region --instance-ids $instance
```
We need to check the application status on regular interval to get "200 OK" message. Initialize a variable with value say, 15 and use curl to check the status till the count reaches 15. In between if we get "200 OK" status then exit the loop and continue with the next step.

*Command:*
```
status=500
until [ $status -eq 200 ]; do
    echo "Application is still not up.. HTTP status: $status"
    sleep 10
    status=$(curl -s -o /dev/null -w '%{http_code}' http://$instance_pvip/testall)
    counter=`expr $counter + 1`
    if [ $counter -gt 10 ]
    then
       echo "Application is Down"
       exit 1
    fi
done
echo "Got $status. All Good!"
```

**Sample output:**
```
Procceding to reboot instance a0-3
Application is still not up.. HTTP status: 500
Got 200. All Good!
```

**4.Add the node back to the load balancer.**

Once the maintenance is completed and the application is up. We can add the instance back to LB.

*Command:* 
```
aws elb register-instances-with-load-balancer --region=$region --load-balancer-name $lb --instances $instance
```
**Sample output:**
```
Adding target back to LB
{
    "Instances": [
        {
            "InstanceId": "i-0c137c56b308ce3c5"
        },
        {
            "InstanceId": "i-03ece495a76794506"
        }
    ]
}
```
Now the backup has been taken for the first instance. Since we are performing it in a loop. The same actions will be carried out for the other instances attached to the LB.

**5.Remove the old backups and AMIs along with the EBS volume snapshots that are no longer needed.**

Once the backup has been taken for all the instances, we can delete the old backup AMI's that no longer needed. Here, we are deleting all AMI and snapshot's except the one taken today. We can get the creation date of the image and compare it with the current date to delete AMI's.

 *Command:* 
```
 image_date=($(aws ec2 describe-images --region=$region --image-ids=$image_id  --query Images[].CreationDate --output=text | cut -d'T' -f1))
 imgdt=$(date -d $image_date +%s)
 current_date=$(date +%Y-%m-%d)
 todate=$(date -d $current_date +%s)
 ```
 If todays's date is greater than image date, then it will delete the image. Before deleting the AMI, it will display the metadata of the AMI going to be deleted.

 *Command:* 
```
if [[ "$todate" > "$imgdt" ]];
  then
    echo "Following AMI older than 1 day : $image_id"
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
  ```

Taking a backup of your infrastructure resources frequently is very important in order to be able to recover from a disaster. It’s important to schedule AWS backups on a timely basis, such as taking backup weekly or monthly.

Reference:
https://docs.aws.amazon.com/cli/latest/userguide/aws-cli.pdf

