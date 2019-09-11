FROM python:2
RUN apt-get update && DEBIAN_FRONTEND=noninteractive apt-get install -y libsasl2-dev libldap2-dev && pip install python-ldap && rm -rf /var/lib/apt/lists/*
COPY nginx-ldap-auth-daemon /
CMD [ "/nginx-ldap-auth-daemon" ]
