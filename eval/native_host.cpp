// CPU reference evaluator using the same tokenizer/grammar/greedy sampler as
// Android's llama_jni.cpp. Fresh context per prompt; no phone latency claims.
#include "llama.h"
#include <fstream>
#include <iostream>
#include <iterator>
#include <string>
#include <vector>
std::string read(const char* path) {
 std::ifstream f(path); return {std::istreambuf_iterator<char>(f),{}};
}
int main(int argc,char** argv) {
 if(argc!=5) return 2;
 llama_log_set([](ggml_log_level,const char*,void*){},nullptr);
 llama_backend_init();
 auto mp=llama_model_default_params(); mp.n_gpu_layers=0;
 auto* model=llama_model_load_from_file(argv[1],mp); if(!model) return 3;
 auto cp=llama_context_default_params(); cp.n_ctx=4096; cp.n_batch=4096;
 cp.n_threads=4; cp.n_threads_batch=4; cp.no_perf=true;
 auto* ctx=llama_init_from_model(model,cp); if(!ctx) return 4;
 const auto* vocab=llama_model_get_vocab(model);
 auto prompt=read(argv[2]),grammar=read(argv[3]); const int limit=std::stoi(argv[4]);
 int n=-llama_tokenize(vocab,prompt.data(),prompt.size(),nullptr,0,true,true);
 if(n<=0 || n+limit>4096) return 5;
 std::vector<llama_token> tokens(n);
 llama_tokenize(vocab,prompt.data(),prompt.size(),tokens.data(),n,true,true);
 auto* sampler=llama_sampler_chain_init(llama_sampler_chain_default_params());
 auto* gs=llama_sampler_init_grammar(vocab,grammar.c_str(),"root"); if(!gs) return 6;
 llama_sampler_chain_add(sampler,gs); llama_sampler_chain_add(sampler,llama_sampler_init_greedy());
 if(llama_decode(ctx,llama_batch_get_one(tokens.data(),n))) return 7;
 for(int i=0;i<limit;i++) {
  auto token=llama_sampler_sample(sampler,ctx,-1);
  if(llama_vocab_is_eog(vocab,token)) break;
  char piece[4096]; int count=llama_token_to_piece(vocab,token,piece,sizeof(piece),0,false);
  if(count<0) return 8;
  std::cout.write(piece,count);
  if(i+1<limit && llama_decode(ctx,llama_batch_get_one(&token,1))) return 9;
 }
 llama_sampler_free(sampler); llama_free(ctx); llama_model_free(model); llama_backend_free();
}
