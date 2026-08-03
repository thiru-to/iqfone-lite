# iqfone-lite 

i want to build a very simplified version of my service to launch immediately.

this is what i'm thinking:
- setup a freeswitch and postgresql setup.
- at launch, incoming calls will have 3 destinations. Softphone, Voicemail or Call-Forward, nothing else.
- let's build a quick, but comprehensive plan with what's entailed for this. 
- i'll use the existing database schemas offered by freeswitch to make this process simpler.
- the only option that we really need to focus on is the dynamic directory xml that handles auth, and the dialplans.
- we will be using bulkvs for both incoming and outgoing calls
- emails will be sent out by sendmail, but we will need to configure opendkim, spf etc to make sure voicemail notifications are sent successfully. I have the ability to update the dns for the domain.
- i will be hosting the app with vultr or buyvm (frantech) on a KVM slice..
