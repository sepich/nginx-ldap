FROM python:2
RUN apt-get update && apt-get install libsasl2-dev libldap2-dev && pip install python-ldap
COPY nginx-ldap-auth-daemon /
CMD [ "/nginx-ldap-auth-daemon" ]
