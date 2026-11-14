#!/usr/bin/env python3
"""Local test fixture. It is explicitly a mock renderer, never an actual Samsung."""
import http.server, socketserver, socket, threading, json, sys
class Renderer(http.server.BaseHTTPRequestHandler):
    def log_message(self,*args): pass
    def do_GET(self):
        port=self.server.server_port
        data=f'''<root xmlns="urn:schemas-upnp-org:device-1-0"><URLBase>http://127.0.0.1:{port}/base/</URLBase><device><friendlyName>Samsung &amp; Test</friendlyName><modelName>MockRenderer</modelName><UDN>uuid:fixture-tv</UDN><serviceList><service><serviceType>urn:schemas-upnp-org:service:AVTransport:1</serviceType><controlURL>/transport</controlURL></service><service><serviceType>urn:schemas-upnp-org:service:ConnectionManager:1</serviceType><controlURL>connection</controlURL></service></serviceList></device></root>'''.encode()
        self.send_response(200);self.send_header('Content-Length',str(len(data)));self.end_headers();self.wfile.write(data)
    def do_POST(self):
        body=self.rfile.read(int(self.headers.get('Content-Length','0'))).decode()
        action=self.headers.get('SOAPAction','').strip('"').split('#')[-1]
        if action=='GetProtocolInfo': contents='<Sink>http-get:*:video/mpeg:*</Sink>';code=200
        elif action=='GetTransportInfo':contents='<CurrentTransportState>PLAYING</CurrentTransportState>';code=200
        elif action=='Unsupported':contents='<s:Fault><detail><UPnPError><errorCode>701</errorCode><errorDescription>Transition not available</errorDescription></UPnPError></detail></s:Fault>';code=500
        elif action=='SetAVTransportURI':
            import xml.etree.ElementTree as ET
            root=ET.fromstring(body);metadata=next(n.text for n in root.iter() if n.tag=='CurrentURIMetaData');didl=ET.fromstring(metadata)
            if self.path=='/liveTransport':
                resource=next(n for n in didl.iter() if n.tag.endswith('}res'))
                assert resource.attrib['protocolInfo']=='http-get:*:video/mpeg:DLNA.ORG_OP=00;DLNA.ORG_CI=0;DLNA.ORG_FLAGS=81000000000000000000000000000000'
            contents='';code=200
        else:contents='';code=200
        data=f'<s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/"><s:Body>{contents}</s:Body></s:Envelope>'.encode()
        self.send_response(code);self.send_header('Content-Length',str(len(data)));self.end_headers();self.wfile.write(data)
server=http.server.ThreadingHTTPServer(('127.0.0.1',0),Renderer)
threading.Thread(target=server.serve_forever,daemon=True).start()
udp=socket.socket(socket.AF_INET,socket.SOCK_DGRAM);udp.bind(('127.0.0.1',0))
def listen():
    while True:
        data,addr=udp.recvfrom(8192)
        if b'M-SEARCH * HTTP/1.1' in data:
            msg=f'HTTP/1.1 200 OK\r\nLOCATION: http://127.0.0.1:{server.server_port}/description\r\nST: ssdp:all\r\n\r\n'.encode()
            udp.sendto(msg,addr);udp.sendto(msg,addr)
threading.Thread(target=listen,daemon=True).start()
print(json.dumps({'http':server.server_port,'udp':udp.getsockname()[1]}),flush=True)
threading.Event().wait()
