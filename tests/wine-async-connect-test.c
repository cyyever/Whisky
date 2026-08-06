#define WIN32_LEAN_AND_MEAN
#include <winsock2.h>
#include <ws2tcpip.h>
#include <mswsock.h>
#include <stdio.h>

/* Reproduce the webhelper failure: Chromium's network service uses overlapped
 * (IOCP) sockets via ConnectEx + overlapped WSASend. A plain blocking connect
 * to the same IP succeeds, so test BOTH here and compare. */
int main(void){
    WSADATA wsa; if(WSAStartup(MAKEWORD(2,2),&wsa)){fprintf(stderr,"WSAStartup fail\n");return 1;}
    const char* ips[]={"199.232.211.82","208.64.203.173"};
    for(int i=0;i<2;i++){
        /* --- blocking connect --- */
        SOCKET b=socket(AF_INET,SOCK_STREAM,0);
        struct sockaddr_in a={0}; a.sin_family=AF_INET; a.sin_port=htons(443);
        a.sin_addr.s_addr=inet_addr(ips[i]);
        int rb=connect(b,(struct sockaddr*)&a,sizeof(a));
        fprintf(stderr,"%-16s blocking connect: %s (err %d)\n", ips[i],
                rb==0?"OK":"FAIL", rb==0?0:WSAGetLastError());
        closesocket(b);

        /* --- overlapped ConnectEx (what Chromium uses) --- */
        SOCKET s=WSASocketW(AF_INET,SOCK_STREAM,0,NULL,0,WSA_FLAG_OVERLAPPED);
        struct sockaddr_in la={0}; la.sin_family=AF_INET; la.sin_addr.s_addr=INADDR_ANY;
        bind(s,(struct sockaddr*)&la,sizeof(la));  /* ConnectEx requires a bound socket */
        LPFN_CONNECTEX pConnectEx=NULL; GUID g=WSAID_CONNECTEX; DWORD nb=0;
        if(WSAIoctl(s,SIO_GET_EXTENSION_FUNCTION_POINTER,&g,sizeof(g),
                    &pConnectEx,sizeof(pConnectEx),&nb,NULL,NULL)!=0){
            fprintf(stderr,"%-16s ConnectEx ptr: FAILED (err %d)\n",ips[i],WSAGetLastError());
            closesocket(s); continue;
        }
        OVERLAPPED ov={0}; ov.hEvent=WSACreateEvent();
        BOOL ok=pConnectEx(s,(struct sockaddr*)&a,sizeof(a),NULL,0,NULL,&ov);
        int err=WSAGetLastError();
        if(!ok && err==ERROR_IO_PENDING){
            if(WSAWaitForMultipleEvents(1,&ov.hEvent,TRUE,10000,FALSE)==WSA_WAIT_EVENT_0){
                DWORD xf=0,fl=0;
                ok=WSAGetOverlappedResult(s,&ov,&xf,FALSE,&fl);
                err=ok?0:WSAGetLastError();
            } else err=WSAGetLastError();
        }
        fprintf(stderr,"%-16s ConnectEx (async): %s (err %d)\n", ips[i], ok?"OK":"FAIL", err);
        WSACloseEvent(ov.hEvent); closesocket(s);
    }
    return 0;
}
