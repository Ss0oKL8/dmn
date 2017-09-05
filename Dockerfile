FROM alpine:3.6

MAINTAINER your mom
LABEL description="dash masternode for kubernetes goodness.."

RUN apk add --no-cache --update grep curl py-virtualenv p7zip openssl libevent boost boost-program_options 

#which network do you want this build to use?
#for mainnet: NETWORK:unset BOOTSTRAP:mainnet DASH_OPTS:unset EXPOSE:9999
ENV BOOTSTRAP mainnet
EXPOSE 9999
ENV BRANCH master

#for testnet: NETWORK:testnet3 BOOTSTRAP:testnet DASH_OPTS:-testnet EXPOSE:19999,19998
#ENV NETWORK testnet3
#ENV BOOTSTRAP testnet
#ENV DASH_OPTS -testnet
#EXPOSE 19999
#EXPOSE 19998
#ENV BRANCH v0.12.2.x

ADD dash /dash
ENV HOME /dash

#compile dash if its not already in this container. 
RUN [ -f /dash/dashd ]&& exit 0;\
  apk add --update bash grep curl git py-virtualenv gnupg p7zip tar libtool automake autoconf openssl-dev libevent-dev boost-dev build-base gcc abuild binutils util-linux pciutils usbutils coreutils binutils findutils cmake \
  && cd /dash \
  && git clone https://github.com/dashpay/dash.git dash-src -b ${BRANCH}\
  && cd /dash/dash-src \
  && wget http://download.oracle.com/berkeley-db/db-4.8.30.NC.tar.gz \
  && tar -xzf db-4.8.30.NC.tar.gz \
  && cd /dash/dash-src/db-4.8.30.NC/build_unix \
  && ../dist/configure --enable-cxx --disable-shared --with-pic --prefix=/dash/dash-src/db4 \
  && make install \
  && cd /dash/dash-src \
  && ./autogen.sh \
  && ./configure --enable-cxx --disable-shared --with-pic LDFLAGS="-L$(pwd)/db4/lib/" CPPFLAGS="-I$(pwd)/db4/include/" \
  && make -j$(nproc)\
  && strip src/dashd src/dash-cli \
  && cp -v src/dashd src/dash-cli /dash/. \
  && cd /dash \
  && git clone https://github.com/dashpay/sentinel.git \
  && cd /dash/sentinel \
  && virtualenv venv \
  && venv/bin/pip install -r requirements.txt \
  && cd /dash \
  && ln -s ~ ~/.dashcore \
  && rm -rf dash-src \
  && apk del tar libtool automake autoconf openssl-dev libevent-dev boost-dev build-base gcc abuild binutils util-linux pciutils usbutils coreutils binutils findutils cmake

#ensure sentinel is set up. 
RUN [ -f /dash/sentinel/venv/bin/python ] && exit 0; \
  cd /dash/sentinel \
  && virtualenv venv \
  && venv/bin/pip install -r requirements.txt 

RUN adduser -D -h /dash dash 
RUN ln -s /dash/dashd /usr/bin/.
RUN ln -s /dash/dash-cli /usr/bin/.
RUN chown dash:dash -R /dash 
RUN ln -s /dash /dash/.dashcore
USER dash
WORKDIR /dash

RUN [ "${DASH_OPTS}" = "-testnet" ]&& ( echo testnet=true >> dash.conf;sed -i -e 's/mainnet/testnet/' sentinel/sentinel.conf) || true

#fetch to semi recent block
#warning! makes for large image, but fast startup times.
#sorry it has to be in one big RUN. other wise the 'bootstrap.dat' 
#would be caught in one of the layers of the image. bloating crap up more
RUN bootstrapurl=$(curl https://github.com/UdjinM6/dash-bootstrap|grep -e ${BOOTSTRAP} -A 1 |grep -oPe "https://.*bootstrap\.dat\.\w*\.zip"|head -n1) \
  && echo fetching bootstrap: $bootstrapurl \
  && curl -v $bootstrapurl -o /tmp/bootstrap.dat.zip \
  && 7z x -o./${NETWORK} /tmp/bootstrap.dat.zip \
  && rm /tmp/bootstrap.dat.zip \
   ; dashd ${DASH_OPTS}\
  &  sleep 10 \
  && echo "processing bootstrap.dat" \
  && grep -e bootstrap /dash/${NETWORK}/*.log \
  && while ! BLOCKS=$(grep -e external /dash/${NETWORK}/*.log|grep -oPe "Loaded \K\d+");do t=$(dash-cli ${DASH_OPTS} getinfo|grep -oPe "blocks\":\ \K\d+"); [ "${t:-0}" -gt 0 ]&&(echo -n ${t:-0}" ");sleep .2;done \
  && echo waiting for all $BLOCKS to be loaded in. \
  && while [ ${t:-0} -lt $BLOCKS ]; do t=$(dash-cli ${DASH_OPTS} getinfo|grep -oPe "blocks\":\ \K\d+"); echo -n ${t:-0}" "; sleep 10;done \
  && dash-cli ${DASH_OPTS} getinfo;dash-cli ${DASH_OPTS} mnsync status;dash-cli ${DASH_OPTS} stop;sleep 10 \
  && rm /dash/${NETWORK}/bootstrap*
  #these can be moved up if you think it will help startup times. 
  #&& echo waiting for isSynced status to be true: \
  #&& while ! dash-cli -testnet mnsync status|grep -e IsSynced\":\ true;do sleep .2;done \

#alternative to using the bootstrap:
#ENV BLOCKS 668075
#RUN dashd ${DASH_OPTS}& sleep 10;echo "syncing blocks(this will take a while)"; while [ ${t:-0} -lt $BLOCKS ];do t=$(dash-cli getinfo|grep blocks); t=${t##* };t=${t%,};echo -n ${t:-0}" "; sleep 10;done;dash-cli getinfo;dash-cli stop;sleep 10

#alt #2
RUN dashd ${DASH_OPTS}& sleep 10;echo "syncing blocks(this will take a while)"; while ! dash-cli mnsync status|grep -q 'IsBlockchainSynced": true' ; do t=$(dash-cli getinfo|grep blocks); t=${t##* };t=${t%,};echo -n ${t:-0}" "; sleep 10;done;dash-cli getinfo;dash-cli stop;sleep 10

RUN rm /dash/${NETWORK}/wallet.dat

#VOLUME /dash

WORKDIR /dash
CMD [ -n "${MNIP}" ] && echo -e "externalip=${MNIP%:*}\nmasternodeprivkey=$MNKEY\nmasternode=1\n" >> /dash/dash.conf; (cd sentinel;while sleep 60;do venv/bin/python bin/sentinel.py;done)& exec dashd -printtoconsole ${DASH_OPTS}

