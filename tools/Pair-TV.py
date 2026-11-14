#!/usr/bin/env python3
"""Read-only SSDP discovery. Python 3 standard library, macOS or Windows."""
import pathlib
import subprocess
import sys
import urllib.parse
import socket
import time
import urllib.request
import xml.etree.ElementTree as ET

locations = set()
with socket.socket(socket.AF_INET, socket.SOCK_DGRAM, socket.IPPROTO_UDP) as sock:
    sock.settimeout(0.5)
    sock.setsockopt(socket.IPPROTO_IP, socket.IP_MULTICAST_TTL, 2)
    for target in ('urn:schemas-upnp-org:device:MediaRenderer:1', 'ssdp:all'):
        message = ('M-SEARCH * HTTP/1.1\r\nHOST: 239.255.255.250:1900\r\n'
                   'MAN: "ssdp:discover"\r\nMX: 2\r\nST: ' + target + '\r\n\r\n')
        sock.sendto(message.encode('ascii'), ('239.255.255.250', 1900))
    print('Searching for TVs on the current LAN...', flush=True)
    until = time.monotonic() + 5
    while time.monotonic() < until:
        try:
            data, _ = sock.recvfrom(65535)
        except socket.timeout:
            continue
        for line in data.decode('utf-8', errors='replace').splitlines():
            key, separator, value = line.partition(':')
            if separator and key.lower() == 'location':
                url = value.strip()
                if url.startswith(('http://', 'https://')):
                    locations.add(url)

def local(tag):
    return tag.rsplit('}', 1)[-1]

found = False
for url in sorted(locations):
    try:
        with urllib.request.urlopen(url, timeout=4) as response:
            data = response.read(1024 * 1024)
        if b'<!DOCTYPE' in data.upper() or b'<!ENTITY' in data.upper():
            continue
        root = ET.fromstring(data)
        if not any(local(n.tag) == 'serviceType' and ':AVTransport:' in (n.text or '') for n in root.iter()):
            continue
        device = next((n for n in root.iter() if local(n.tag) == 'device'), root)
        fields = {local(n.tag): (n.text or '').strip() for n in device}
        print('\nDEVICE:', fields.get('friendlyName', '?'))
        print('MODEL:', fields.get('modelName', '?'))
        print('DESCRIPTION URL:', url)
        found = True
        if sys.platform == 'darwin':
            pairing = 'screenmirror://pair?' + urllib.parse.urlencode({'url': url})
            destination = pathlib.Path.home() / 'Desktop' / ('ScreenMirror-TV-' + str(len(locations)) + '-' + str(abs(hash(url)) % 10000) + '.png')
            swift = """import Foundation
import CoreImage
import AppKit
let input = CommandLine.arguments[1]
let path = CommandLine.arguments[2]
let filter = CIFilter(name: "CIQRCodeGenerator")!
filter.setValue(Data(input.utf8), forKey: "inputMessage")
filter.setValue("M", forKey: "inputCorrectionLevel")
let code = filter.outputImage!.transformed(by: CGAffineTransform(scaleX: 10, y: 10))
let bounds = CGRect(x: 0, y: 0, width: code.extent.width + 80, height: code.extent.height + 80)
let white = CIImage(color: CIColor.white).cropped(to: bounds)
let image = code.transformed(by: CGAffineTransform(translationX: 40, y: 40)).composited(over: white)
let context = CIContext()
let cg = context.createCGImage(image, from: bounds)!
let bitmap = NSBitmapImageRep(cgImage: cg)
try bitmap.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: path))
"""
            result = subprocess.run(['swift', '-', pairing, str(destination)], input=swift, text=True, capture_output=True)
            if result.returncode == 0:
                print('QR CODE:', destination)
                subprocess.run(['open', str(destination)], check=False)
            else:
                print('QR generation failed:', result.stderr)

    except Exception as error:
        print('Could not inspect', url, ':', error)
if not found:
    print('No AVTransport devices found. Check same LAN, TV power, VPN and network permission.')
    print('This result alone does not prove the TV is unsupported.')
