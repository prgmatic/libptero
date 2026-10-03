# VADPCM host codec

Vendored unchanged from libdragon commit
`5cb976aab11eb30622c33b112c120a1107eedb5e`,
`tools/audioconv64/vadpcm/codec`. Author: Dietrich Epp.
License: MPL-2.0; see LICENSE.txt and the source notices.
Only host asset compilation links this codec. Runtime decoding uses normal ZSP.
The four-predictor, order-two encoder is the same implementation libdragon uses.
