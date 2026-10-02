# Third-party dependencies

The optional cover derivative module uses [Pillow](https://github.com/python-pillow/Pillow) 12.3.0, licensed under MIT-CMU. Pillow's installed wheel retains its `pillow-12.3.0.dist-info/licenses/LICENSE`, including notices for bundled image codecs. Keep that directory when distributing the Docker image. Do not substitute notices from another platform's wheel.

The implementation also uses Python's standard library. No Komga, Nuke, Kingfisher, SDWebImage or Gifu source code was copied into these changes; their documented design approaches informed independent implementations.

## Isolated experiments (not production dependencies)

Only the independently implemented bounded-queue experiment is included here for
synthetic tests. No pyvips/libvips experiment image or native binary is distributed
in this source tree. This experiment is not copied by the production Dockerfile;
production uses Pillow. No upstream queue implementation was copied.

Pillow / PIL license:

The Python Imaging Library (PIL) is

    Copyright © 1997-2011 by Secret Labs AB
    Copyright © 1995-2011 by Fredrik Lundh and contributors

Pillow is the friendly PIL fork. It is

    Copyright © 2010 by Jeffrey 'Alex' Clark and contributors

By obtaining, using, and/or copying this software and/or its associated
documentation, you agree that you have read, understood, and will comply
with the following terms and conditions:

Permission to use, copy, modify and distribute this software and its
documentation for any purpose and without fee is hereby granted,
provided that the above copyright notice appears in all copies, and that
both that copyright notice and this permission notice appear in supporting
documentation, and that the name of Secret Labs AB or the author not be
used in advertising or publicity pertaining to distribution of the software
without specific, written prior permission.

SECRET LABS AB AND THE AUTHOR DISCLAIMS ALL WARRANTIES WITH REGARD TO THIS
SOFTWARE, INCLUDING ALL IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS.
IN NO EVENT SHALL SECRET LABS AB OR THE AUTHOR BE LIABLE FOR ANY SPECIAL,
INDIRECT OR CONSEQUENTIAL DAMAGES OR ANY DAMAGES WHATSOEVER RESULTING FROM
LOSS OF USE, DATA OR PROFITS, WHETHER IN AN ACTION OF CONTRACT, NEGLIGENCE
OR OTHER TORTIOUS ACTION, ARISING OUT OF OR IN CONNECTION WITH THE USE OR
PERFORMANCE OF THIS SOFTWARE.
