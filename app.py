import os
import shutil
import tempfile

from fastapi import BackgroundTasks, Depends, FastAPI, File, Form, HTTPException, UploadFile
from fastapi.concurrency import run_in_threadpool
from fastapi.middleware.cors import CORSMiddleware
from fastapi.security import HTTPAuthorizationCredentials, HTTPBearer
from pydantic import BaseModel
from supabase import create_client

from rag_modell import (
    UPLOAD_STATUS,
    build_rag_chain,
    delete_document,
    get_or_create_thread,
    get_thread_messages,
    ingest_document_background,
    list_documents,
    query,
    save_message,
)

app = FastAPI(title="ChatDocs RAG API")

app.add_middleware(
    CORSMiddleware,
    allow_origins=["*"],
    allow_credentials=True,
    allow_methods=["*"],
    allow_headers=["*"],
)

# used only to verify tokens (get_user), not for db access
_auth_client = create_client(os.getenv("SUPABASE_URL"), os.getenv("SUPABASE_SECRET_KEY"))
_bearer = HTTPBearer()


def get_current_user_id(creds: HTTPAuthorizationCredentials = Depends(_bearer)) -> str:
    """
    verifies the supabase access token sent by the flutter app and returns
    the real, authenticated user id. user_id is never taken from the
    request body/form anymore - it always comes from this token.
    """
    try:
        response = _auth_client.auth.get_user(creds.credentials)
    except Exception:
        raise HTTPException(status_code=401, detail="invalid or expired token")

    if not response or not response.user:
        raise HTTPException(status_code=401, detail="invalid or expired token")

    return response.user.id


class ChatRequest(BaseModel):
    doc_id: str
    question: str


@app.post("/upload")
async def upload(
    background_tasks: BackgroundTasks,
    file: UploadFile = File(...),
    doc_id: str = Form(...),
    user_id: str = Depends(get_current_user_id),
):
    suffix = os.path.splitext(file.filename or "")[1]
    with tempfile.NamedTemporaryFile(delete=False, suffix=suffix) as tmp:
        shutil.copyfileobj(file.file, tmp)
        tmp_path = tmp.name

    # returns immediately - chunking + embedding a large document can take
    # long enough to exceed railway's request timeout (this is what caused
    # 502s on the 60-page test), so ingestion runs in the background and
    # the client polls /upload/{doc_id}/status instead of waiting on this
    # request. the temp file is cleaned up inside the background task,
    # once it's actually done reading the file.
    background_tasks.add_task(
        ingest_document_background,
        tmp_path,
        user_id,
        doc_id,
        file.filename,
    )

    return {"status": "processing", "doc_id": doc_id}


@app.get("/upload/{doc_id}/status")
async def upload_status(doc_id: str, user_id: str = Depends(get_current_user_id)):
    status = UPLOAD_STATUS.get(doc_id)
    if status is None:
        # either it hasn't started, doc_id is wrong, or the server
        # restarted since the upload was queued (this status is in
        # memory only, not persisted)
        raise HTTPException(status_code=404, detail="no upload found for this doc_id")
    return status


@app.post("/chat")
async def chat(payload: ChatRequest, user_id: str = Depends(get_current_user_id)):
    try:
        chain = await run_in_threadpool(build_rag_chain, user_id, payload.doc_id)
        result = await run_in_threadpool(query, chain, payload.question)
    except Exception as exc:
        raise HTTPException(status_code=500, detail=str(exc))

    # the answer is already generated at this point - if saving history
    # fails, the user still gets their answer, they just won't see this
    # exchange in their thread later. that's a reasonable trade rather
    # than failing a successful answer over a logging problem.
    try:
        documents = await run_in_threadpool(list_documents, user_id)
        filename = next((d["filename"] for d in documents if d["doc_id"] == payload.doc_id), "document")
        thread_id = await run_in_threadpool(get_or_create_thread, user_id, payload.doc_id, filename)
        await run_in_threadpool(save_message, thread_id, "user", payload.question)
        await run_in_threadpool(
            save_message, thread_id, "assistant", result["answer"], result["provider"], result["sources"]
        )
    except Exception:
        pass

    return result


@app.get("/chat/{doc_id}/history")
async def get_chat_history(doc_id: str, user_id: str = Depends(get_current_user_id)):
    try:
        messages = await run_in_threadpool(get_thread_messages, user_id, doc_id)
    except Exception as exc:
        raise HTTPException(status_code=500, detail=str(exc))

    return {"messages": messages}


@app.get("/documents")
async def get_documents(user_id: str = Depends(get_current_user_id)):
    try:
        documents = await run_in_threadpool(list_documents, user_id)
    except Exception as exc:
        raise HTTPException(status_code=500, detail=str(exc))

    return {"documents": documents}


@app.delete("/document/{doc_id}")
async def remove_document(doc_id: str, user_id: str = Depends(get_current_user_id)):
    try:
        await run_in_threadpool(delete_document, doc_id, user_id)
    except Exception as exc:
        raise HTTPException(status_code=500, detail=str(exc))

    return {"status": "deleted"}


if __name__ == "__main__":
    import uvicorn

    uvicorn.run("app:app", host="0.0.0.0", port=int(os.getenv("PORT", 8000)))