#!/usr/bin/env bash
# Package a stream-optimized VMDK into a minimal, VirtualBox-importable OVA.
#   mk-ova.sh <disk.vmdk> <out.ova> <vm-name> <disk_size_gb>
set -euo pipefail
VMDK="${1:?vmdk}"; OVA="${2:?ova}"; NAME="${3:?name}"; SIZE_GB="${4:?size_gb}"

WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT
DISK_BASENAME="$(basename "$VMDK")"
cp "$VMDK" "$WORK/$DISK_BASENAME"

CAP=$(( SIZE_GB * 1024 * 1024 * 1024 ))
POP=$(stat -c%s "$WORK/$DISK_BASENAME")
OVF="$WORK/${NAME}.ovf"

cat > "$OVF" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<Envelope ovf:version="1.0" xml:lang="en-US"
    xmlns="http://schemas.dmtf.org/ovf/envelope/1"
    xmlns:ovf="http://schemas.dmtf.org/ovf/envelope/1"
    xmlns:rasd="http://schemas.dmtf.org/wbem/wscim/1/cim-schema/2/CIM_ResourceAllocationSettingData"
    xmlns:vssd="http://schemas.dmtf.org/wbem/wscim/1/cim-schema/2/CIM_VirtualSystemSettingData">
  <References>
    <File ovf:href="$DISK_BASENAME" ovf:id="file1" ovf:size="$POP"/>
  </References>
  <DiskSection>
    <Info>Virtual disk information</Info>
    <Disk ovf:capacity="$CAP" ovf:diskId="vmdisk1" ovf:fileRef="file1"
          ovf:format="http://www.vmware.com/interfaces/specifications/vmdk.html#streamOptimized"
          ovf:populatedSize="$POP"/>
  </DiskSection>
  <NetworkSection>
    <Info>Logical networks</Info>
    <Network ovf:name="NAT"><Description>NAT network</Description></Network>
  </NetworkSection>
  <VirtualSystem ovf:id="$NAME">
    <Info>RawOS appliance</Info>
    <OperatingSystemSection ovf:id="96">
      <Info>Ubuntu 64-bit</Info>
      <Description>Ubuntu_64</Description>
    </OperatingSystemSection>
    <VirtualHardwareSection>
      <Info>Virtual hardware requirements</Info>
      <System>
        <vssd:ElementName>Virtual Hardware Family</vssd:ElementName>
        <vssd:InstanceID>0</vssd:InstanceID>
        <vssd:VirtualSystemType>virtualbox-2.2</vssd:VirtualSystemType>
      </System>
      <Item>
        <rasd:Caption>4 virtual CPU</rasd:Caption><rasd:InstanceID>1</rasd:InstanceID>
        <rasd:ResourceType>3</rasd:ResourceType><rasd:VirtualQuantity>4</rasd:VirtualQuantity>
      </Item>
      <Item>
        <rasd:AllocationUnits>MegaBytes</rasd:AllocationUnits>
        <rasd:Caption>8192 MB of memory</rasd:Caption><rasd:InstanceID>2</rasd:InstanceID>
        <rasd:ResourceType>4</rasd:ResourceType><rasd:VirtualQuantity>8192</rasd:VirtualQuantity>
      </Item>
      <Item>
        <rasd:Caption>sataController0</rasd:Caption><rasd:InstanceID>3</rasd:InstanceID>
        <rasd:ResourceSubType>AHCI</rasd:ResourceSubType><rasd:ResourceType>20</rasd:ResourceType>
      </Item>
      <Item>
        <rasd:Caption>disk1</rasd:Caption><rasd:InstanceID>4</rasd:InstanceID>
        <rasd:HostResource>/disk/vmdisk1</rasd:HostResource><rasd:Parent>3</rasd:Parent>
        <rasd:ResourceType>17</rasd:ResourceType>
      </Item>
    </VirtualHardwareSection>
  </VirtualSystem>
</Envelope>
EOF

# OVA = tar with the .ovf first, then disk. (Manifest optional; omitted for simplicity.)
tar -C "$WORK" -cf "$OVA" "$(basename "$OVF")" "$DISK_BASENAME"
echo "[mk-ova] wrote $OVA"
