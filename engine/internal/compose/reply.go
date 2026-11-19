package compose

import (
	"net/mail"
	"strings"

	"github.com/stubbedev/email.nvim/engine/internal/message"
)

type Identity interface {
	Owns(address string) bool
}

type Reply struct {
	To         []*mail.Address
	Cc         []*mail.Address
	Subject    string
	InReplyTo  string
	References string
	Recipient  string
}

var deliveryHeaders = []string{"To", "Cc", "Bcc", "Envelope-To", "X-Original-To", "Delivered-To"}

func BuildReply(original *message.Message, me Identity, all bool) Reply {
	reply := Reply{
		Subject:    replySubject(original.Get("Subject")),
		InReplyTo:  strings.TrimSpace(original.Header.Get("Message-Id")),
		References: references(original),
	}
	for _, address := range original.Addresses(deliveryHeaders...) {
		if me.Owns(address.Address) {
			reply.Recipient = address.Address
			break
		}
	}
	from := original.Addresses("From")
	to := original.Addresses("To")
	cc := original.Addresses("Cc")
	fromMe := len(from) > 0 && me.Owns(from[0].Address)
	seen := map[string]bool{}
	add := func(list *[]*mail.Address, candidates []*mail.Address, skipMine bool) {
		for _, address := range candidates {
			key := strings.ToLower(address.Address)
			if seen[key] || (skipMine && me.Owns(address.Address)) {
				continue
			}
			seen[key] = true
			*list = append(*list, address)
		}
	}
	if fromMe {
		add(&reply.To, to, false)
		if all {
			add(&reply.Cc, cc, false)
		}
		return reply
	}
	primary := original.Addresses("Reply-To")
	if len(primary) == 0 || redundant(primary, to, cc) {
		primary = from
	}
	add(&reply.To, primary, false)
	if all {
		add(&reply.To, to, true)
		add(&reply.Cc, cc, true)
	}
	return reply
}

func redundant(replyTo, to, cc []*mail.Address) bool {
	if len(replyTo) != 1 {
		return false
	}
	for _, list := range [][]*mail.Address{to, cc} {
		for _, address := range list {
			if strings.EqualFold(address.Address, replyTo[0].Address) {
				return true
			}
		}
	}
	return false
}

func replySubject(subject string) string {
	if len(subject) >= 3 && strings.EqualFold(subject[:3], "re:") {
		return subject
	}
	return "Re: " + subject
}

func references(original *message.Message) string {
	id := strings.TrimSpace(original.Header.Get("Message-Id"))
	prior := strings.Join(strings.Fields(original.Header.Get("References")), " ")
	if prior == "" {
		prior = strings.TrimSpace(original.Header.Get("In-Reply-To"))
	}
	if prior == "" {
		return id
	}
	if id == "" {
		return prior
	}
	return prior + " " + id
}

func Display(address *mail.Address) string {
	if address.Name == "" {
		return address.Address
	}
	name := address.Name
	if strings.ContainsAny(name, "()<>[]:;@\\,.\"") {
		name = `"` + strings.NewReplacer(`\`, `\\`, `"`, `\"`).Replace(name) + `"`
	}
	return name + " <" + address.Address + ">"
}

func DisplayList(list []*mail.Address) string {
	formatted := make([]string, len(list))
	for i, address := range list {
		formatted[i] = Display(address)
	}
	return strings.Join(formatted, ", ")
}
