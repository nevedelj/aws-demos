#!/bin/bash

### We will create bucket, upload some object and modify a bucket policy.
BUCKET_NAME="s3-demo-bucket-w$(date +%V)-y$(date +%Y)"
VPCID="vpc-06e14917bdde880a6"
ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
CURL_CLIENT_IP=$(curl 'https://api.ipify.org?format=text' 2> /dev/null)

echo "Bucket name: ${BUCKET_NAME}"
echo "VPC ID: ${VPCID}"
echo "Account ID: ${ACCOUNT_ID}"
echo "Client IP - curl: ${CURL_CLIENT_IP}"

# Let's **create S3 bucket** for our data
aws s3 mb s3://${BUCKET_NAME}

# Now we'll copy data to it
aws s3 cp /etc/resolv.conf s3://${BUCKET_NAME}/s3intro/

# Let's try to **download it using curl** (no authentication)
# This should return permission denied
curl https://s3.eu-central-1.amazonaws.com/${BUCKET_NAME}/s3intro/resolv.conf 

# But I can still access the object via authenticated API call using SDK or CLI (or REST API directly).
aws s3 cp s3://${BUCKET_NAME}/s3intro/resolv.conf /tmp/resolv.conf-s3bucket
echo && cat /tmp/resolv.conf-s3bucket
rm /tmp/resolv.conf-s3bucket

# We'll add some bucket policy
BUCKET_POLICY=$(cat <<-END
{
    "Version": "2012-10-17",
    "Id": "DemoAccessPolicy20210630",
    "Statement": [
        {
            "Effect": "Allow",
            "Principal": "*",
            "Action": "s3:GetObject",
            "Resource": "arn:aws:s3:::${BUCKET_NAME}/s3intro/*",
            "Condition": {
                "IpAddress": {
                    "aws:SourceIp": "${CURL_CLIENT_IP}/32"
                }
            }
        }
    ]
}
END
)

aws s3api put-bucket-policy \
    --bucket ${BUCKET_NAME} \
    --policy "${BUCKET_POLICY}"
echo "RESULT: $?"

curl https://${BUCKET_NAME}.s3.eu-central-1.amazonaws.com/s3intro/resolv.conf 


### S3 Access Points
# Now I'll create an access point.
# But first, let's make sure the content is only accessible via Access Points, not via S3 bucket directly.

BUCKET_POLICY=$(cat <<-END
{
    "Version": "2012-10-17",
    "Id": "DemoAccessPolicy20210630",
    "Statement": [
        {
            "Effect": "Deny",
            "Principal": "*",
            "Action": "s3:GetObject",
            "Resource": "arn:aws:s3:::${BUCKET_NAME}/*",
            "Condition": {
                "StringNotEquals" : { 
                    "s3:DataAccessPointAccount" : "${ACCOUNT_ID}" 
                }
            }
        }
    ]
}
END
)

aws s3api put-bucket-policy \
    --bucket ${BUCKET_NAME} \
    --policy "${BUCKET_POLICY}"
    
echo "RESULT: $?" && echo

aws s3 cp s3://${BUCKET_NAME}/s3intro/resolv.conf /tmp/test-resolv.conf-s3

# Create access point for public internet accessible content
aws s3control create-access-point \
    --account-id ${ACCOUNT_ID} \
    --name auth-public-internet \
    --bucket ${BUCKET_NAME}
    
echo "RESULT: $?" && echo

# Let's make sure the access point has been created.
aws s3control list-access-points --account-id ${ACCOUNT_ID}

# Copy some content over to the bucket
echo "<h1>HI THERE</h1>" > /tmp/my-page.html
aws s3 cp /tmp/my-page.html s3://${BUCKET_NAME}/public/
aws s3 cp /etc/nanorc s3://${BUCKET_NAME}/public/nanorc

# Assign appropriate tags to objects
aws s3api put-object-tagging --bucket ${BUCKET_NAME} \
    --key public/my-page.html \
    --tagging '{"TagSet": [{"Key": "access-type", "Value": "internet"}]}'
    
echo "RESULT: ${?}"

# I'll create a policy which will make only properly tagged content accessible.
# Create Access Point policies
cat <<EOPOLICY > /tmp/ap-public-policy.json
{
    "Version": "2012-10-17",
    "Statement": [
        {
            "Effect": "Allow",
            "Principal": {
                "AWS": "${ACCOUNT_ID}"
            },
            "Action": "s3:GetObject",
            "Resource": "arn:aws:s3:eu-central-1:${ACCOUNT_ID}:accesspoint/auth-public-internet/object/public/*",
            "Condition" : {
                "StringEquals": {
                    "s3:ExistingObjectTag/access-type": "internet"
                }
            }
        },
        {
            "Effect": "Deny",
            "Principal": "*",
            "Action": "s3:GetObject",
            "Resource": "arn:aws:s3:eu-central-1:${ACCOUNT_ID}:accesspoint/auth-public-internet/object/public/*",
            "Condition" : {
                "StringNotEquals": {
                    "s3:ExistingObjectTag/access-type": "internet"
                }
            }            
        }
    ]
}
EOPOLICY

aws s3control put-access-point-policy \
    --account-id ${ACCOUNT_ID} \
    --name auth-public-internet \
    --policy file:///tmp/ap-public-policy.json
    
echo "RESULT: ${?}"

# Attempt to get the html file (properly tagged one) - this should work
aws s3api get-object \
    --bucket ${BUCKET_NAME} \
    --key public/my-page.html \
    --bucket arn:aws:s3:eu-central-1:${ACCOUNT_ID}:accesspoint/auth-public-internet \
    /tmp/my-page.html-from-s3

echo && cat /tmp/my-page.html-from-s3 
rm /tmp/my-page.html-from-s3

# Attempt to get the *nanorc* file (properly tagged one) - this should NOT work
aws s3api get-object \
    --bucket ${BUCKET_NAME} \
    --key public/nanorc \
    --bucket arn:aws:s3:eu-central-1:${ACCOUNT_ID}:accesspoint/auth-public-internet \
    /tmp/nanorc-from-s3   # this should work from  public internet

# Let's tag the nanorc file to make it accessible.
aws s3api put-object-tagging --bucket ${BUCKET_NAME} \
    --key public/nanorc \
    --tagging '{"TagSet": [{"Key": "access-type", "Value": "internet"}]}'
    
echo "RESULT: ${?}"

# Can I get it now?
aws s3api get-object \
    --bucket ${BUCKET_NAME} \
    --key public/nanorc \
    --bucket arn:aws:s3:eu-central-1:${ACCOUNT_ID}:accesspoint/auth-public-internet \
    /tmp/nanorc-from-s3   # this should work from  public internet

echo && cat /tmp/nanorc-from-s3 
rm /tmp/nanorc-from-s3


### S3 Transfer Acceleration
# Let's see how to enable transfer acceleration on the S3 bucket and how to use it. 

# First, we need to clean up the bucket policy created earlier
aws s3api delete-bucket-policy \
    --bucket ${BUCKET_NAME}
    
echo "RESULT: ${?}"

# Enable the accelleration on the bucket:
aws s3api put-bucket-accelerate-configuration \
    --bucket ${BUCKET_NAME} \
    --accelerate-configuration Status=Enabled
    
echo "RESULT: ${?}"

# Let's see how to access the bucket data via accelerated endpoint.
aws s3 cp s3://${BUCKET_NAME}/s3intro/resolv.conf /tmp/resolv.conf-accelerated \
    --region eu-central-1 \
    --endpoint-url https://s3-accelerate.amazonaws.com

echo && cat /tmp/resolv.conf-accelerated
rm /tmp/resolv.conf-accelerated

# Let's allow unauthenticated access to some of the objects and try to get the file using curl.
BUCKET_POLICY=$(cat <<-END
{
    "Version": "2012-10-17",
    "Id": "DemoAccessPolicy20210630",
    "Statement": [
        {
            "Effect": "Allow",
            "Principal": "*",
            "Action": "s3:GetObject",
            "Resource": "arn:aws:s3:::${BUCKET_NAME}/s3intro/*",
            "Condition": {
                "IpAddress": {
                    "aws:SourceIp": "${CURL_CLIENT_IP}/32"
                }
            }
        }
    ]
}
END
)

aws s3api put-bucket-policy \
    --bucket ${BUCKET_NAME} \
    --policy "${BUCKET_POLICY}"
    
echo "RESULT: $?"

curl http://${BUCKET_NAME}.s3-accelerate.amazonaws.com/s3intro/resolv.conf


### CLEAN UP
aws s3control delete-access-point\
    --account-id ${ACCOUNT_ID} \
    --name auth-public-internet
    
aws s3 rb --force s3://${BUCKET_NAME} 