# AKI ids from:
#  http://docs.aws.amazon.com/AWSEC2/latest/UserGuide/UserProvidedkernels.html
# These are pv-grub-hd0_1.04-x86_64

declare -A ALL_AKIS
ALL_AKIS["us-east-1"]=aki-919dcaf8
ALL_AKIS["us-east-2"]=aki-da055ebf
ALL_AKIS["us-west-1"]=aki-880531cd
ALL_AKIS["us-west-2"]=aki-fc8f11cc
ALL_AKIS["eu-west-1"]=aki-52a34525
ALL_AKIS["eu-central-1"]=aki-184c7a05
ALL_AKIS["ap-south-1"]=aki-a7305ac8
ALL_AKIS["ap-southeast-1"]=aki-503e7402
ALL_AKIS["ap-southeast-2"]=aki-c362fff9
ALL_AKIS["ap-northeast-1"]=aki-176bf516
ALL_AKIS["ap-northeast-2"]=aki-01a66b6f
ALL_AKIS["sa-east-1"]=aki-5553f448

MAIN_REGIONS=( "${!ALL_AKIS[@]}" )

# The following are isolated regions
ALL_AKIS["us-gov-west-1"]=aki-1de98d3e

ALL_REGIONS=( "${!ALL_AKIS[@]}" )
