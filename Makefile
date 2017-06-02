INSTALL_DIR?=/usr/local/bin
MAN_DIR?=/usr/local/man/man1
ETC_DIR?=/etc
VERSION=$(shell egrep '^my .version' colordiff.pl |cut -f 2 -d "'")
DIST_FILES=COPYING INSTALL Makefile README \
	colordiff.pl colordiffrc colordiffrc-lightbg cdiff.sh BUGS CHANGES colordiff.1 \
	colordiff.xml cdiff.xml cdiff.1 colordiffrc-gitdiff
TMPDIR=colordiff-${VERSION}
TARBALL=${TMPDIR}.tar.gz

.PHONY: doc
doc: colordiff.xml cdiff.xml
	xmlto -vv man colordiff.xml
	xmlto -vv man cdiff.xml
	xmlto -vv txt colordiff.xml
	xmlto -vv html-nochunks colordiff.xml
	mv colordiff.txt README
	perl -p -i -e 's#<head>#<head><link rel=\"stylesheet\" type=\"text/css\" href=\"colordiff.css\">#' colordiff.html
	perl -p -i -e 's#</body>#</div></body>#' colordiff.html
	perl -p -i -e 's#<div class=\"refentry\"#<div id=\"content\"><div class=\"refentry\"#' colordiff.html

.PHONY: install
install:
	install -d ${DESTDIR}${INSTALL_DIR}
	sed -e "s%/etc%${ETC_DIR}%g" colordiff.pl > \
	  ${DESTDIR}${INSTALL_DIR}/colordiff
	chmod +x ${DESTDIR}${INSTALL_DIR}/colordiff
	if [ ! -f ${DESTDIR}${INSTALL_DIR}/cdiff ] ; then \
	  install cdiff.sh ${DESTDIR}${INSTALL_DIR}/cdiff; \
	fi
	install -Dm 644 colordiff.1 ${DESTDIR}${MAN_DIR}/colordiff.1
	install -Dm 644 cdiff.1 ${DESTDIR}${MAN_DIR}/cdiff.1
	if [ -f ${DESTDIR}${ETC_DIR}/colordiffrc ]; then \
	  mv -f ${DESTDIR}${ETC_DIR}/colordiffrc \
	    ${DESTDIR}${ETC_DIR}/colordiffrc.old; \
	else \
	  install -d ${DESTDIR}${ETC_DIR}; \
	fi
	cp colordiffrc ${DESTDIR}${ETC_DIR}/colordiffrc
	-chown root.root ${DESTDIR}${ETC_DIR}/colordiffrc
	chmod 644 ${DESTDIR}${ETC_DIR}/colordiffrc

.PHONY: uninstall
uninstall:
	rm -f ${DESTDIR}${INSTALL_DIR}/colordiff
	rm -f ${DESTDIR}${ETC_DIR}/colordiffrc
	rm -f ${DESTDIR}${INSTALL_DIR}/cdiff
	rm -f ${DESTDIR}${MAN_DIR}/colordiff.1
	rm -f ${DESTDIR}${MAN_DIR}/cdiff.1

.PHONY: dist
dist:
	mkdir ${TMPDIR}
	cp -p ${DIST_FILES} ${TMPDIR}
	tar -zcvf ${TARBALL} ${TMPDIR}
	rm -fR ${TMPDIR}

.PHONY: gitclean
gitclean:
	rm -f colordiff.1 colordiff.html cdiff.1

.PHONY: clean
clean:
	rm -f README colordiff.1 colordiff.html cdiff.1
