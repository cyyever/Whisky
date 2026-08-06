#define WIN32_LEAN_AND_MEAN
#include <winsock2.h>
#include <ws2tcpip.h>
#include <stdio.h>
int main(void){
    WSADATA wsa; if(WSAStartup(MAKEWORD(2,2),&wsa)){fprintf(stderr, "WSAStartup fail\n");return 1;}
    const char* ips[]={"199.232.211.82","8.8.8.8","1.1.1.1"};
    for(int i=0;i<3;i++){
        SOCKET s=socket(AF_INET,SOCK_STREAM,0);
        struct sockaddr_in a={0}; a.sin_family=AF_INET; a.sin_port=htons(443);
        a.sin_addr.s_addr=inet_addr(ips[i]);
        u_long nb=1; ioctlsocket(s,FIONBIO,&nb); /* non-blocking */
        int r=connect(s,(struct sockaddr*)&a,sizeof(a));
        int err=WSAGetLastError();
        if(r!=0 && err==WSAEWOULDBLOCK){
            fd_set w; FD_ZERO(&w); FD_SET(s,&w); struct timeval tv={5,0};
            if(select(0,NULL,&w,NULL,&tv)>0){ r=0; }
            else { err=WSAGetLastError(); }
        }
        fprintf(stderr, "connect %-16s:443 -> %s (WSA err %d)\n", ips[i], r==0?"OK":"FAIL", r==0?0:err);
        closesocket(s);
    }
    return 0;
}
