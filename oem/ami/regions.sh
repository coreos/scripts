# AKI ids from:
#  http://docs.aws.amazon.com/AWSEC2/latest/UserGuide/UserProvidedkernels.html
# we need pv-grub-hd00 x86_64

declare -A ALL_AKIS
ALL_AKIS["us-east-1"]=aki-b4aa75dd
ALL_AKIS["us-west-1"]=aki-eb7e26ae
ALL_AKIS["us-west-2"]=aki-f837bac8
ALL_AKIS["eu-west-1"]=aki-8b655dff
ALL_AKIS["eu-central-1"]=aki-184c7a05
ALL_AKIS["ap-southeast-1"]=aki-fa1354a8
ALL_AKIS["ap-southeast-2"]=aki-3d990e07
ALL_AKIS["ap-northeast-1"]=aki-40992841
ALL_AKIS["sa-east-1"]=aki-c88f51d5
# ALL_AKIS["gov-west-1"]=aki-75a4c056

ALL_REGIONS=( "${!ALL_AKIS[@]}" )
