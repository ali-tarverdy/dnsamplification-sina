/* -*- P4_16 -*- */
#include <core.p4>
#include <v1model.p4>

const bit<16> TYPE_IPV4 = 0x800;
const bit<8> PROTOCOL_UDP = 0x11;
const bit<16> DNS_PORT = 53;
const bit<16> DNS_RESPONSE_FLAG = 0x8000;

#define MAX_DNS_SIZE 50

/*************************************************************************
*********************** H E A D E R S  ***********************************
*************************************************************************/

typedef bit<9>  egressSpec_t;
typedef bit<48> macAddr_t;
typedef bit<32> ip4Addr_t;

header ethernet_t {
	macAddr_t dstAddr;
	macAddr_t srcAddr;
	bit<16>   etherType;
}

header ipv4_t {
	bit<4>	version;
	bit<4>	ihl;
	bit<8>	diffserv;
	bit<16>   totalLen;
	bit<16>   identification;
	bit<3>	flags;
	bit<13>   fragOffset;
	bit<8>	ttl;
	bit<8>	protocol;
	bit<16>   hdrChecksum;
	ip4Addr_t srcAddr;
	ip4Addr_t dstAddr;
}

header udp_t {
	bit<16> srcPort;
	bit<16> dstPort;
	bit<16> len;
	bit<16> checksum;
}

/*
header dns_t {
	bit<16> id;
	bit<16> flags;
	bit<16> qcount;
	bit<16> ancount;
	bit<16> nscount;
	bit<16> arcount;
}
*/

header dns_t {
    bit<16> id;
    bit<1> is_response;
    bit<4> opcode;
    bit<1> auth_answer;
    bit<1> trunc;
    bit<1> recur_desired;
    bit<1> recur_avail;
    bit<1> reserved;
    bit<1> authentic_data;
    bit<1> checking_disabled;
    bit<4> resp_code;
    bit<16> qcount;
    bit<16> answer_count;
    bit<16> auth_rec;
    bit<16> addn_rec;
}

header dns_question_t {
	bit<8> len;
	bit<16> type;
	bit<16> class;
}

struct metadata {
	ip4Addr_t nexthop;
}

struct headers {
	ethernet_t   ethernet;
	ipv4_t	   ipv4;
	udp_t		udp;
	dns_t		dns;
//	dns_question_t question;
}

/*************************************************************************
*********************** P A R S E R  ***********************************
*************************************************************************/

parser MyParser(packet_in packet,
				out headers hdr,
				inout metadata meta,
				inout standard_metadata_t standard_metadata) {

	state start {
		transition parse_ethernet;
	}

	state parse_ethernet {
		packet.extract(hdr.ethernet);
		transition select(hdr.ethernet.etherType) {
			TYPE_IPV4: parse_ipv4;
			default: accept;
		}
	}

	state parse_ipv4 {
		packet.extract(hdr.ipv4);
		transition select(hdr.ipv4.protocol) {
			PROTOCOL_UDP: parse_udp;
			default: accept;
		}
	}

	state parse_udp {
		packet.extract(hdr.udp);
		transition select(hdr.udp.dstPort) {
			DNS_PORT: parse_dns;
			default: accept;
		}
	}

	state parse_dns {
		packet.extract(hdr.dns);
		transition accept;
	}

}

/*************************************************************************
************   C H E C K S U M	V E R I F I C A T I O N   *************
*************************************************************************/

control MyVerifyChecksum(inout headers hdr, inout metadata meta) {
	apply {  }
}

/*************************************************************************
**************  I N G R E S S   P R O C E S S I N G   *******************
*************************************************************************/

control MyIngress(inout headers hdr,
				  inout metadata meta,
				  inout standard_metadata_t standard_metadata) {
	action drop() {
		mark_to_drop(standard_metadata);
	}
	
	action ipv4_forward(macAddr_t dstAddr, egressSpec_t port) {
		standard_metadata.egress_spec = port;
		hdr.ethernet.srcAddr = hdr.ethernet.dstAddr;
		hdr.ethernet.dstAddr = dstAddr;
		hdr.ipv4.ttl = hdr.ipv4.ttl - 1;
	}

	action set_nhop(ip4Addr_t nexthop, egressSpec_t port) {
		meta.nexthop = nexthop;
		standard_metadata.egress_spec = port;	
		hdr.ipv4.ttl = hdr.ipv4.ttl - 1;
	}

	action set_dmac(macAddr_t dmac) {
		hdr.ethernet.dstAddr = dmac;
	}
	table forward {
		key = {
			meta.nexthop : exact;	
		}
		actions = {
			set_dmac;
			drop;
		}
		size = 512;
	}

	table ipv4_lpm {
		key = {
			hdr.ipv4.dstAddr: lpm;
		}
		actions = {
			ipv4_forward;
			drop;
			NoAction;
			set_nhop;
		}
		size = 1024;
		default_action = drop();
	}

	apply {

		if (hdr.ipv4.isValid() && hdr.udp.isValid() && (hdr.udp.srcPort == DNS_PORT)) {
			if (hdr.dns.isValid() && hdr.udp.len > 512) {
				drop();
			} else {
				ipv4_lpm.apply();
				forward.apply();
			} 
		} else if (hdr.ipv4.isValid()) {
			ipv4_lpm.apply();
			forward.apply();
		}
	}
}

/*************************************************************************
****************  E G R E S S   P R O C E S S I N G   *******************
*************************************************************************/

control MyEgress(inout headers hdr,
				 inout metadata meta,
				 inout standard_metadata_t standard_metadata) {
	apply {  }
}

/*************************************************************************
*************   C H E C K S U M	C O M P U T A T I O N   **************
*************************************************************************/

control MyComputeChecksum(inout headers  hdr, inout metadata meta) {
	 apply {
		update_checksum(
		hdr.ipv4.isValid(),
			{ hdr.ipv4.version,
			  hdr.ipv4.ihl,
			  hdr.ipv4.diffserv,
			  hdr.ipv4.totalLen,
			  hdr.ipv4.identification,
			  hdr.ipv4.flags,
			  hdr.ipv4.fragOffset,
			  hdr.ipv4.ttl,
			  hdr.ipv4.protocol,
			  hdr.ipv4.srcAddr,
			  hdr.ipv4.dstAddr },
			hdr.ipv4.hdrChecksum,
			HashAlgorithm.csum16);
	}
}

/*************************************************************************
***********************  D E P A R S E R  *******************************
*************************************************************************/

control MyDeparser(packet_out packet, in headers hdr) {
	apply {
		packet.emit(hdr.ethernet);
		packet.emit(hdr.ipv4);
		packet.emit(hdr.udp);
		packet.emit(hdr.dns);
	}
}

/*************************************************************************
***********************  S W I T C H  *******************************
*************************************************************************/

V1Switch(
MyParser(),
MyVerifyChecksum(),
MyIngress(),
MyEgress(),
MyComputeChecksum(),
MyDeparser()
) main;
