
import time

from cython.parallel import prange                                              

from libcpp.vector cimport vector
from libcpp.set cimport set as oset
from libcpp.string cimport string
from libcpp.pair cimport pair
from libcpp.map cimport map as omap
from libcpp cimport bool                                                        
from libc.stdio cimport printf, fprintf, fopen, fclose, FILE, sprintf

from py_stringsimjoin.apply_rf.execution_plan import get_predicate_dict
from py_stringsimjoin.apply_rf.tokenizers cimport tokenize, load_tok
from py_stringsimjoin.apply_rf.set_sim_join cimport set_sim_join
from py_stringsimjoin.apply_rf.overlap_coefficient_join cimport ov_coeff_join                
from py_stringsimjoin.apply_rf.edit_distance_join cimport ed_join   
from py_stringsimjoin.apply_rf.sim_functions cimport cosine, dice, jaccard      
from py_stringsimjoin.apply_rf.utils cimport compfnptr, simfnptr, get_comp_type, get_comparison_function, get_sim_type, get_sim_function

from py_stringsimjoin.apply_rf.predicatecpp cimport Predicatecpp                
from py_stringsimjoin.apply_rf.node cimport Node                                


def ex_plan(plan, rule_sets, df1, attr1, df2, attr2, working_dir, n_jobs):                                          
    cdef vector[string] lstrings, rstrings                                      
    convert_to_vector1(df1[attr1], lstrings)                                    
    convert_to_vector1(df2[attr2], rstrings)
    execute_plan(plan, rule_sets, lstrings, rstrings, working_dir, n_jobs)           

cdef void execute_plan(Node& root, vector[string]& lstrings, 
        vector[string]& rstrings, const string& working_dir, int n_jobs):
#    tokenize_strings(plan, rule_sets, lstrings, rstrings, working_dir)

    cdef vector[pair[int, int]] candset, curr_candset
#    cdef Node root
    print root.children.size(), root.children[0].children.size()

    cdef Node join_node, child_node, curr_node
    print len(plan.root.children), root.node_type, root.predicates.size(), root.children.size()
    for join_node in root.children:
         print 'JOIN', join_node.predicates[0].sim_measure_type, join_node.predicates[0].tokenizer_type, join_node.predicates[0].comp_op, join_node.predicates[0].threshold
         candset = execute_join_node(lstrings, rstrings, join_node.predicates[0], 
                                     n_jobs, working_dir)
         for child_node in join_node.children:
             curr_node = child_node
             curr_candset = candset

             while curr_node.node_type.compare('OUTPUT') != 0:
                 print 'FILTER', curr_node.predicates[0].sim_measure_type, curr_node.predicates[0].tokenizer_type, curr_node.predicates[0].comp_op, curr_node.predicates[0].threshold
                 curr_candset = execute_filter_node(curr_candset, lstrings, rstrings, 
                                    curr_node.predicates[0], n_jobs, working_dir)
                 print 'filter done'
                 print curr_node.children.size()
                 curr_node = curr_node.children[0]
             
             print 'candset after join : ', candset.size() , " , candset at output : ", curr_candset.size()                        

cdef vector[pair[int, int]] execute_join_node(vector[string]& lstrings, vector[string]& rstrings,
                            Predicatecpp predicate, int n_jobs, const string& working_dir):
    cdef vector[vector[int]] ltokens, rtokens
    load_tok(predicate.tokenizer_type, working_dir, ltokens, rtokens)               

    cdef vector[pair[int, int]] output

    if predicate.sim_measure_type.compare('COSINE') == 0:
        output = set_sim_join(ltokens, rtokens, 0, predicate.threshold)
    elif predicate.sim_measure_type.compare('DICE') == 0:
        output = set_sim_join(ltokens, rtokens, 1, predicate.threshold)                   
    elif predicate.sim_measure_type.compare('JACCARD') == 0:
        output = set_sim_join(ltokens, rtokens, 2, predicate.threshold)                   
    return output

cdef vector[pair[int, int]] execute_filter_node(vector[pair[int, int]]& candset, vector[string]& lstrings, vector[string]& rstrings,
                            Predicatecpp predicate, int n_jobs, const string& working_dir):
    cdef vector[vector[int]] ltokens, rtokens
    print 'before tok'                                   
    load_tok(predicate.tokenizer_type, working_dir, ltokens, rtokens)           
    print 'loaded tok'                                                                            
    cdef vector[pair[int, int]] partitions, final_output_pairs, part_pairs                    
    cdef vector[vector[pair[int, int]]] output_pairs                            
    cdef int n = candset.size(), start=0, end, i

    partition_size = <int>(<float> n / <float> n_jobs)                           

    for i in range(n_jobs):                                                      
        end = start + partition_size                                            
        if end > n or i == n_jobs - 1:                                           
            end = n                                                             
        partitions.push_back(pair[int, int](start, end))                        
                                                   
        start = end                                                             
        output_pairs.push_back(vector[pair[int, int]]())    

    cdef int sim_type, comp_type                                                     
                                                                                
    sim_type = get_sim_type(predicate.sim_measure_type)                       
    comp_type = get_comp_type(predicate.comp_op)     
    print 'parallen begin'
    for i in prange(n_jobs, nogil=True):                                         
        execute_filter_node_part(partitions[i], candset, ltokens, rtokens, 
                                 predicate, sim_type, comp_type, output_pairs[i])
    print 'parallen end'
    for part_pairs in output_pairs:                                             
        final_output_pairs.insert(final_output_pairs.end(), part_pairs.begin(), part_pairs.end())
                                                                             
    return final_output_pairs 

cdef void execute_filter_node_part(pair[int, int] partition,
                                   vector[pair[int, int]]& candset,                           
                                   vector[vector[int]]& ltokens, 
                                   vector[vector[int]]& rtokens,                       
                                   Predicatecpp& predicate,
                                   int sim_type, int comp_type, 
                                   vector[pair[int, int]]& output_pairs) nogil:

    cdef pair[int, int] cand                         
    cdef int i                           
    
    cdef simfnptr sim_fn = get_sim_function(sim_type)
    cdef compfnptr comp_fn = get_comparison_function(comp_type)
                                                      
    for i in range(partition.first, partition.second):                                                        
        cand  = candset[i]
        if comp_fn(sim_fn(ltokens[cand.first], rtokens[cand.second]), predicate.threshold):
            output_pairs.push_back(cand)         
 
cdef void tokenize_strings(plan, rule_sets, vector[string]& lstrings, 
                      vector[string]& rstrings, const string& working_dir):
    tokenizers = infer_tokenizers(plan, rule_sets)
    cdef string tok_type
    for tok_type in tokenizers:
        tokenize(lstrings, rstrings, tok_type, working_dir)

def test_tok1(df1, attr1, df2, attr2):                                                         
    cdef vector[string] lstrings, rstrings                                                 
    convert_to_vector1(df1[attr1], lstrings)
    convert_to_vector1(df2[attr2], rstrings)
    tokenize(lstrings, rstrings, 'ws', 'gh')                       
  
cdef void convert_to_vector1(string_col, vector[string]& string_vector):         
    for val in string_col:                                                      
        string_vector.push_back(val)   

cdef vector[string] infer_tokenizers(plan, rule_sets):
    cdef vector[string] tokenizers
    predicate_dict = get_predicate_dict(rule_sets)

    queue = []
    queue.extend(plan.root.children)
    cdef string s
    while len(queue) > 0:
        curr_node = queue.pop(0)

        if curr_node.node_type in ['JOIN', 'FEATURE', 'FILTER']:
            pred = predicate_dict.get(curr_node.predicate)
            s = pred.tokenizer_type
            tokenizers.push_back(s)
    
        if curr_node.node_type == 'OUTPUT':
            continue
        queue.extend(curr_node.children)
    return tokenizers

def test_jac(df1, attr1, df2, attr2, sim_type, threshold):
    st = time.time()
    print 'tokenizing'
    #test_tok1(df1, attr1, df2, attr2)
    print 'tokenizing done.'
    cdef vector[vector[int]] ltokens, rtokens
    cdef vector[pair[int, int]] output
    load_tok('ws', 'gh', ltokens, rtokens)
    print 'loaded tok'
    if sim_type == 3:
        output = ov_coeff_join(ltokens, rtokens, threshold)             
    else:
        output = set_sim_join(ltokens, rtokens, sim_type, threshold)
    print 'output size : ', output.size()
    print 'time : ', time.time() - st

def test_ed(df1, attr1, df2, attr2, threshold):                      
    st = time.time()                                                            
    print 'tokenizing'                                                          
    cdef vector[string] lstrings, rstrings                                      
    convert_to_vector1(df1[attr1], lstrings)                                    
    convert_to_vector1(df2[attr2], rstrings)  
    tokenize(lstrings, rstrings, 'qg2', 'gh1')                                    
    print 'tokenizing done.'                                                    
    cdef vector[vector[int]] ltokens, rtokens                                   
    cdef vector[pair[int, int]] output                                          
    load_tok('qg2', 'gh1', ltokens, rtokens)                                      
    print 'loaded tok'                                                          
    output = ed_join(ltokens, rtokens, 2, threshold, lstrings, rstrings)            
    print 'output size : ', output.size()                                       
    print 'time : ', time.time() - st                                           
                                        
